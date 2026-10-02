# HANDOFF — current work first

Updated 2026-10-01 (late). Read [the documentation map](docs/README.md) for the
difference between source, published releases and historical plans. Update the
**Current state** and **In flight** sections when stopping work. What comes next
is in **[ROADMAP.md](ROADMAP.md)**.

**Live == GitHub `master` == `5cef60e`** (check: `curl https://muffindevelopment.com/death-muffin/play/release.txt`).
Every 2026-10-01 release is committed: brew engine, necromancer weapons and cast
animations, reagents, Mourning Fen, five-slot Grimoire, Death Muffin branding,
the owner-only Auto Combat gate, and the Offline Edition with complete save sync
(migration 016). Earlier that day several releases had gone out from uncommitted
edits; they were reviewed, committed and redeployed from a clean export. The
pre-cleanup tree is preserved on `backup/codex-wip-20261001` and `-b`.

**Deploy only with `server/death-muffin/deploy-release.sh [rev] [migration.sql ...]`.** It
builds play and offline clients from `git archive <rev>` (never the working tree),
runs typecheck and both test suites, backs up the DB and runtime, applies the named
migrations, restarts realtime then auth, publishes assets before entry pages, and
writes `play/release.txt`. The old one-off scripts in `~/death-muffin/deploy/` build
from stale trees and must not be re-run.

Branch `codex/new-blood-release-20260928` tracks `origin/master` (push `HEAD:master`
after a secret scan; the repo is public). The owner asked for commits, which overrides
the older "stage, don't commit" note.

## Server authority, step 1 (branch `dm/server-authority`, 2 Oct 2026, not deployed)

Plausibility guards on `save-progress`, bag saves, `add-item`, `roll-gear` and the offline load/sync-stats, behind `AUTHORITY_MODE=report|enforce` (default report: logs and audit rows only, saves unchanged). Migration `021-server-authority.sql` (`character_authority`, `progress_audit`); ceilings derived from the balance harness in `src/gameplay/authorityRules.ts` (bundled by `npm run build:server-rules` to `gathering/authority-rules.cjs`). Guards fail open and skip staff. Full detail, ceilings, rollout and what is still trusted: `docs/SERVER-AUTHORITY.md`. Probe: `tools/qa/authority-db-probe.cjs` (scratch DB). Deploy with `deploy-release.sh <rev> 021-server-authority.sql`, leave `AUTHORITY_MODE` unset, watch `progress_audit` before enforcing.

## Zone and encounter polish (branch `dm/zone-polish`, 2 Oct 2026, not deployed)

Full audit and before/after in `docs/ZONE-POLISH-AUDIT.md`; the tour is `tools/qa/zone-tour.cjs`. Done: boss cone and line telegraphs now brightened with an outline (new `coneEdge`/`bar` sprites in `fxTextures.ts`, `areaBossEvent` in `WorldScene.ts`); a faint pale ring on every fresh corpse (`EntityViews.ts`, cap 8); Fen wisp-pulse ring brighter; Sanctum and Cloister arena sigils dimmed; Ossuary sky light lifted; three prop overlaps fixed (Ossuary coffin pile, Sanctum pillar behind the altar, Cloister waystone moved to z -111 in `layout.ts` and `areas.ts`). `necro-rules.cjs` was regenerated because `areas.ts` changed. Open: Nave perf and noise, thrall vs pale-enemy silhouette, Fen corpse rings on water, Acre darkness.

## Alchemist's Wing dressing (branch `dm/wing-dressing`, 2 Oct 2026, not deployed)

Reviewers found the Wing sparse. `WING_PROPS` is now ~65 placements, plus `WING_FLOOR` rugs/spills, warm de-purpled floor and wall
textures (`tools/make-wing-textures.mjs`), brightened herb bundles/drying rack (`PROP_LIFT`), and the Sexton holds `tool_spade`
(`NPC_LOOKS.sexton.held`). Perf on Low: Wing 140 calls / 394k tris vs Chapterhouse 125 / 356k (the smoke asserts <= +15%). Details and
screenshots: `docs/ALCHEMIST-WING-ART.md` "Dressing pass". Door lane and station rings are unit-tested.

## First-hour polish (branch `dm/first-hour`, 2 Oct 2026, not deployed)

Audit of a brand-new character's first stretch: `docs/FIRST-HOUR-AUDIT.md` (timeline, findings, before/after). What changed:

- **Counsel cadence** is a pure module, `src/ui/counselCadence.ts` (tests: `src/ui/__tests__/counselCadence.test.ts`). Every tip has a kind: `urgent` (only `hurt`, jumps the
  queue), `danger` (fight-time lessons and enemy telegraphs; shown in a fight, never in a sanctuary or while talking, dropped when stale), `asked` (the player just did the
  thing; shown at once) and `calm` (everything else; waits for no fight / no conversation / no banner / no open panel and a 20 s gap). Tips on one subject (`gear`, `bag`,
  `brew`, `acre`, `road`) keep 150 s apart; place tips (`HERE`) wait for their place; at most 4 calm tips queue. `Onboarding` draws, the cadence decides. New tips: add the id
  to `DANGER`/`ASKED`/`HERE`/`GROUPS`/`PRIORITY` if the default (calm, ungrouped, priority 50) is wrong. `Onboarding.show(id, delayMs, { kind, bump })`.
- The opening is one card ("Take your time"; it also marks the Acre card seen), then the fight lesson on the first dead met in a hunting ground (`move`), not in the Acre.
- The card sits top-left under the hero frame; the Omen chip moved beside the hero frame and the Kill Chain / Bone Ward / brews readouts start lower. Cards are above panels
  and fade for the 3 s area/level banner; toasts step under a banner; the hint line is short; XP bar and chat narrow at 1280; the Damage / Wave Speed panel lifts above the
  Grave Essence orb under 1500 px.
- The Next line from the Acre says "east to the Chapterhouse, then north"; while it shows, the area text under the minimap says what the place is for and drops the seal it
  already counts. Stale "Workbench" brewing directions now point at the Alchemist's Wing (tips, Apothecary, Skills panel, Grave Dust lore, server item text).
- A conversation eases the camera north (`WorldScene.talkFocus`) so the speaker and the hero stay below the card.
- QA: `tools/qa/first-hour-audit.cjs` (plays the hour, logs a timeline, screenshots every popup, detects overlaps; phases A-H), `tools/qa/first-hour-smoke.cjs` (asserts), shared
  helpers in `tools/qa/lib/first-hour-lib.cjs` (virtual UI timers so cards age with game time).

## Animation pass (branch `dm/anim-pass`, 2 Oct 2026, not deployed)

- **Models faced the wrong way.** Every Tripo biped (enemies, thralls, bosses, laborers) faces +X in its GLB and only the
  heroes had the yaw fix, so enemies walked sideways and swung at an angle. `Creature` now yaws any rig with a `Hip` bone
  by -90 degrees; `bone_hound` and `cinderhound` get 180 (head measured at -Z). `graphics/__tests__/creature-locomotion.test.ts` pins it.
- **Foot sliding.** `tools/build-stride-speeds.mjs` writes `src/content/strideSpeeds.json` (planted-foot speed in body
  heights per second, from the clips; run it after adding a model). `graphics/locomotion.ts` turns real ground speed (measured from
  the body's movement) into clip and playback speed; `Creature.setGroundSpeed` applies it. Walk-only rigs are capped
  (3x, less for big bodies), so very fast walkers still slide a little. The old `WALK_SPEED` table is gone.
- **Blends.** Locomotion crossfades 0.28 s (walk/run phase-matched), return from a swing 0.2 s, swings stay at 0.08 s. A hit
  now plays an additive flinch (`Creature.flinch`, also what `playOnce('hurt')` does) over whatever is running. Walk-only rigs
  idle as a slow shuffle. Heroes turn through `turnToward` (max 13 rad/s), enemies max 9.
- **Props.** `gearProps.GRIPS` holds per-kind lean/offset/roll/follow, tuned with `prop-clipping.test.ts` (vertices of the
  prop buried in the skinned body, measured on the real rig). Gathering tools are stood upright and gripped at the handle end.
- **Crowds.** `graphics/crowdSeparation.ts` slides drawn enemies/thralls apart (view layer only, max 0.55 u, eased); the sim is unchanged.
- QA: `tools/qa/anim-pass-smoke.cjs` (port 5336).

## Animation pass 2 (branch `dm/anim-2`, 2 Oct 2026, not deployed)

- **Hitstop** (`graphics/hitstop.ts`): a 2-4 frame freeze of the picture clock only (`Creature.update` and `Effects.update` scale their dt by `hitstop.scale`;
  the sim never sees it). Triggers: a hit taking >=22% of an enemy's max hp (elites 12%) that leaves it standing (this is "big rites", whatever
  casts them), elite deaths within 16 u, boss impacts and boss defeat within 18 u (`WorldScene.BOSS_STOP`). Rationed: 0.3 s gap and a leaky budget,
  so sustained crowd fights freeze about 12% of the time at most. Off under reduced motion.
- **Knockback** (`graphics/knockback.ts`, `EntityViews.onHit`): a critically damped spring on the drawn root, away from the hero, sized by the share of hp
  lost and the body's mass (scale squared; 40% while winding up). Max 0.6 u, settles in about 0.45 s, frozen during hitstop. Sim positions untouched.
- **Death settle** (`EntityViews.settle`): when the death clip reaches its landing moment (`landingTime`, from the Hip height track) the body eases 0.06 u into the
  ground and puffs dust. Only y changes; a corpse's x/z never move. Corpses used to stop animating at 3 s, which froze `death2` (5.6 s) mid-fall;
  they now animate for 6 s.
- **Locomotion:** `grave_robber` and `censer_bearer` got a retargeted biped `run` (20 credits, `art-manifest/anim2-jobs.json`), so they run at a natural cadence
  instead of a 2x walk. Walk-only cap for small bodies is now 4.5x (`WALK_HARD_MAX`). `tools/stride-overrides.json` holds an in-engine stride for `bone_hound`
  (clip-derived 1.474 was about 1.5x too fast; planted feet now ~0 of ground speed instead of +0.3). `tools/measure-clips.mjs` gained `contactStrideOfClip` (mesh-based; agrees with the bone method on
  bipeds). The smoke's slip is now mesh-contact slip, with the old foot-bone number kept as `slipBones`.
- **Robed casters:** their old 0.5-0.7 "slip" was mostly the metric (the 22%-of-height planted window counts their low swing as planted); with a 10% window the feet are at 0.14 vs the robber's 0.11. Remaining mesh slip is robe hem.
- **Resolved on `dm/blender`:** `skull_rat` and `cinderhound` slid (fixed by procedural gaits, see the Blender section above). Original note: `skull_rat` and `cinderhound` still slide. Their rigs have leaf bones that are not feet and (cinderhound) legs that move against each other, so neither
  bone nor mesh metrics are trustworthy on them. A quadruped run preset does not exist. The honest fix is a new quadruped model/rig or a hand-keyed gait.
- QA: `tools/qa/anim-pass-smoke.cjs` (port 5342 used here) now also checks hitstop / knockback / settle and the hound's planted feet; `DM_QA_IMPACT_ONLY`, `DM_QA_ENEMIES_ONLY`, `DM_QA_ONLY=def,def` narrow it.

## Blender animation pipeline (branch `dm/blender`, 2 Oct 2026, not deployed)

- **What:** `tools/blender.mjs` + `tools/blender/*.py` (headless Blender 4.5 at `/home/ubuntu/tools/blender/blender`): `procedural` (quadruped gaits and idles from
  `tools/blender/recipes/*.json`), `rigfix` (new bones + re-weighting), `cleanup` (loop seam, root drift, IK foot-lock), `retarget` (CC0 Quaternius clips onto the Tripo biped
  via `tools/blender/maps/`). Output is `anim_<name>.glb`, so `build-characters.mjs` is unchanged. Full guide, bone map, limits: `docs/BLENDER-PIPELINE.md`; sources/licences: `docs/ANIMATION-SOURCES.md`.
- **Shipped (models rebuilt):** `skull_rat` and `cinderhound` now have `idle`, `walk` and `run` (procedural; Tripo's walk preset is kept in `art-src/tripo/<slug>/orig/`). The cinderhound got two
  foreleg bone chains (`rigfix`): its forelegs used to be skinned to the neck/chest bone, which is why its legs worked against each other. Browser mesh slip (`anim-pass-smoke`): rat 0.72 -> 0.06,
  cinderhound 1.27 -> 0.08 (`slipFeet` 1.04 -> 0.06 and 1.53 -> 0.08). `strideSpeeds.json`: rat walk 0.623 / run 5.362, cinderhound walk 0.589 / run 3.19 (body heights per second).
- **Measurement fix:** the old quadruped slip counted tail/head vertices and took the floor from one toe; The smoke now
  masks to the recipe's legs, uses a percentile floor, refreshes the skeleton before reading vertices, and reports `slipFeet`. (Its biped mean read 0.21 on 2026-10-02; the biped method is unchanged apart from the defensive skeleton refresh.) `measure-clips.mjs --stride <glb> <clip> --legs <recipe>` is the offline equivalent.
- **Not shipped:** the UAL retarget proof on `hero_gravecaller` (`art-src/blender/retarget/`; strips in `docs/screenshots/blender/retarget-*.png`). Cast is not clearly better than the shipped one, idle is a 2.5 s loop against a 15 s
  shipped one; the spell-ready idle and talk gestures are candidates for new hooks. Decision is the orchestrator's.
- Dev server for this branch used port 5345; `tools/qa/clip-strip.cjs` renders side-view frame strips (carry the body at the clip's ground speed with `--speed N --abs` to see planted feet on the ground ticks).

## Blender round 2 (branch `dm/blender-2`, 2 Oct 2026, not deployed)

- **bone_hound:** was shipping Tripo's walk, which in the game stretched the cloth/torso weights into a vertical sliver. New skeleton parts via `rigfix` (4 legs + tail), procedural idle/walk/run, no more stride override. Slip 0.85 -> 0.06. **cinderhound:** hock-flex hind legs, open foreleg fold (no shoulder fin). **skull_rat:** tail lifted off the floor in walk/run.
- **belfry_gargoyle:** both wings are bones now; the Tripo clips carry wing motion (overlay), a flap `walk` exists, and the shader flap is off for the gargoyle only. The dive is the unchanged Tripo tumble.
- **NPC talk gesture:** UAL `Idle_Talking_Loop` was retargeted onto the three guides and judged worse; nothing swapped.
- Overwrote files in the shared `art-src/tripo/<slug>/` (originals in `orig/`): see the final report / docs/BLENDER-PIPELINE.md. `tools/qa/anim-pass-smoke.cjs` now takes the hound's feet from its recipe. Details: `docs/BLENDER-PIPELINE.md` "Results, round 2".

## Gear pass (branch `dm/gear-tuning`, 2 Oct 2026, not deployed)

Full write-up, tables and targets: **BALANCE.md "Gear pass"**. Numbers only (no new mechanics, affix ids unchanged); `affix-rules.cjs` was regenerated and must ship with the client.

- **Harness wears gear.** `balance/kits.ts` (kits as data: none, progress, typical, rolled, ascended, bis), `bands.ts`, `gearReport.ts` (`npm run balance:gear`), `leverReport.ts` (`balance:lever`),
  `gearScoreReport.ts` (`balance:score`), `BALANCE_KIT` on `npm run balance`. The bot plays the weapon line and applies corpse heal and the Litany barrier (it ignored both before).
- **Finding: base item stats are ~90% of gear's lift.** A first set + weapon makes push/max Wave Speed nearly safe (deaths 2.0 -> 0.3; ascended -> 0.05). Those stats are DB rows, so not changed here;
  BALANCE.md table 5 shows trimming them to 0.4-0.55x lands the proposed targets. **Open decision for the owner.**
- **Retuned:** affix ranges (stat affixes were worth 7-10% of power each, now 2-3%; levers raised to match for the discipline that uses them), 12 sets' bonuses (necromancer sets lost to Carrionbloom's
  flat INT), `gearStats` constants (`THRALL_DAMAGE_SHARE`, `THRALL_UPTIME`, `REGEN_HORIZON_S`, `SET_VALUE`, `LOADOUT_VALUE`). `docs/ARMOR-SETS.md` table regenerated and checked by `gear-balance.test.ts`.
- **Not confirmed:** Mourner and Rotweaver wearing their own set best (power score says yes, the 32-seed harness reads 1-4% behind Gravecall); scythe is a known score/harness disagreement; levers are measured on a bot that never dodges.

## 60-second orientation

- **What it is:** Death Muffin — browser dark-fantasy ARPG (Vite + TS + Three.js),
  nine classes, one connected world, continuous waves, corpse mechanics,
  Damage & Wave Speed upgrades and co-op ≤10. Player guide: `README.md`.
- **Hard rules:** the original shared Crossworlds REST server is outside this repo
  (write proposals in `server/proposals/`); Death Muffin's separate backend is
  versioned under `server/death-muffin/`. Stage changes for the user's GitHub
  workflow; do not commit unless explicitly asked. Never print or commit keys
  from `.ai-keys.local`.
- **Architecture map + verification recipe:** `CLAUDE.md`.
- **Asset generation (Gemini/Tripo):** `ASSET_PIPELINE.md` — costs, specs, resumable tools.
- **Scope:** focus on the game (mechanics, engine, rendering, content). The user already has a
  login page and an about/landing page elsewhere, so don't build or polish site pages. The
  in-repo `LoginScene`/`CharacterSelectScene` only need to keep working.

## Resume in 5 commands

```bash
npm install                       # Node 24 (winget OpenJS.NodeJS.LTS if missing)
(cd server/realtime && npm ci)     # test:server needs the realtime service's deps (dotenv, socket.io)
npm run typecheck && npm test && npm run test:server
npm run balance                   # headless farming/danger table — targets + current numbers in BALANCE.md
npm run dev                       # or preview "death-muffin-web" in .claude/launch.json
# open http://localhost:5188/?offline  → register any name/password (local mock), pick a discipline
# QA from the console: __cwDebug.god(); __cwDebug.goto('graves'); __cwDebug.advance(3); __cwDebug.counts()
```
Hidden preview panes throttle rendering — drive time with `__cwDebug.advance(seconds)`;
`__cwShot('name')` saves the current frame to `docs/screenshots/`.

## Current state

| Scope | Status | Evidence / next action |
| --- | --- | --- |
| Live release | `5cef60e`, 2026-10-01 23:28 UTC | `deploy-release.sh`; backup `~/death-muffin/deploy/backup-pre-release-5cef60e072b6-*`; live smoke (login, co-op, 9 class cards, Grimoire, no page errors) passed |
| Offline Edition | Downloadable PWA at `/death-muffin/offline/` plus complete save sync with saved versions and restore | Live end-to-end check: load, 409 on a stale fingerprint, 400 on an unknown item with rollback, versions, restore. `offline-edition-smoke.cjs` passes against production |
| Validation | 497 client tests, 88 server tests, typecheck, both builds | Offline-preview smoke suite: 17/21 pass. `necro-audit` exceeds a 600 s cap (run per discipline with `DM_QA_DISC`); `flyers-rites` hits a Playwright "promise was garbage collected" at line 108; `reagents` only collects loot landing within 1.3 m (items do not fly to the player), so it can miss dust; `acre` only fails when `node_modules` is symlinked from outside the Vite root |
| Fixed 2026-10-01 | Server XP curve now `level × 100` like the client; Ritual Sickle no longer refunds an empowered Exhume; held keys repeat slot 5; Leave the world is at the top of Settings | |
| Progression pacing to review | New Blood classes gain XP much more slowly than necromancers in the current Medium bot | Graves level-1 sample: necromancers 364–391 XP/min, New Blood 42–106 XP/min; human checks needed before retuning |
| Housekeeping for the owner | Seven `zz_*` test accounts in the live DB; six merged worktrees in `wt/`; about 11 GB of old update zips and stages in `vps-handoffs/DeathMuffin/` | Owner deletes; nothing was removed |

2026-10-02 necro spell feel (branch `dm/spell-feel`, not deployed): `src/graphics/necroFx.ts` adds capped, Low-skipped, reduced-motion-thinned bone/dirt/soul/spore/skull motifs to every necromancer rite (visuals only). Audit, per-rite before/after sheets and perf notes in `docs/NECRO-SPELL-FEEL.md`; QA: `tools/qa/spell-feel-smoke.cjs`. Frame time was not measurable on the loaded VPS, so check it on a real GPU.

### Historical baseline — verified in 2026-09-26, not a current status table

2026-09-29 local pass: New Blood rites now have distinct procedural cast sounds,
three quiet spell layers from the local Crossworlds Unity archive, and sparse
area detail. High-quality ground VFX warm in small batches; static floor decals
survive dense combat, and the toxic-puddle glow no longer draws a bright square.
Production build, typecheck, VFX tests and browser graphics checks pass. Audio
clips decoded in headless WebAudio; balance and loudness still need an ear-test.
No deployment. (The Crossworlds clips were removed 2026-10-02, see below.)

2026-10-02 combat audio pass (branch `dm/combat-audio`, not deployed): CC0 sample layer
in `public/audio/combat/` (50 files, ~0.55 MB, recipe `tools/audio/build-combat-samples.mjs`,
provenance `docs/AUDIO-SOURCES.md`) over the synth, which remains the fallback. Mixer rules
are pure functions in `src/audio/mixer.ts` (five buses, per-bus voice caps by priority, repeat
attenuation, distance falloff, thrall thinning, ducking); sample map in `src/audio/samples.ts`;
Settings has Combat / Ambience / Interface sliders. QA: `tools/qa/audio-smoke.cjs` (DEV
`window.__cwAudio.stats()`). The mix has been measured but NOT ear-tested. The three
Crossworlds clips are gone (replaced by CC0 layers).

2026-10-02 gentle guidance (branch `dm/guidance`, not deployed): three talkable people (the Prior and the Apothecary in the
Chapterhouse, the Sexton in the Acre) and an optional "Next" line under the minimap. Positions/names/looks: `src/content/npcs.ts`
(stand-in models in `NPC_LOOKS`; swap in `npc_prior` / `npc_sexton` / `npc_apothecary` by adding them to `modelPaths.ts` and editing
the `slug` there; `talk` clip is optional). Pure selectors: `src/gameplay/guidance.ts` (suggestions, news, per-character memory in
`dm_guidance_v1:<charId>`); words: `src/content/dialogue.ts`; UI: `ui/DialoguePanel.ts`, `graphics/NpcViews.ts`, HUD `data-next`, minimap
ping. Key **E**; Settings has two toggles (`guidance`, `guidancePing`, default on). Tests: `gameplay/__tests__/guidance.test.ts`; QA:
`tools/qa/guidance-smoke.cjs`. Suggestion priorities live in `suggestions()`; add a rule there plus a line in `dialogue.ts`.

2026-10-02 audio pass 2 (branch `dm/audio-2`, not deployed): zone beds are now data
(`src/audio/ambience.ts`: per-area loop layers with the old synth wind as fallback, weighted
sparse details with 8-40 s gaps) over five generated 12 s loops in `public/audio/ambience/`; the
bed passes through `bedDuck`, which a leaky combat-activity meter (`CombatActivity` in
`mixer.ts`) pulls to 50% during fights (the boss drum bypasses it; details wait for quiet).
New sample layers in `public/audio/world/` (79 files, recipe `tools/audio/build-world-samples.mjs`)
for gathering and stations (chop, mine, dig, splash, reel, sawpit, kiln, cook, grind, craft,
Vault open/close), the remaining necromancer rites (Frost, Siphon, Prison, Hands, Storm, Soul
Harvest release, the four signatures) and some other classes' rites, panel open/close, equip,
level up, loot (rare / epic distinct), and ambient details. Call sites are one-liners in
`AbilitySystem`, `WorldScene` (`togglePanel`, `onGatherCycle`, `onSalvaged`, loot, equip,
craft by station) and `ForgePanel.station`. The audio smoke prints a per-bus mix report. NOT
ear-tested; all gains were set from measured peaks, not by listening.

| Area | Status | Where |
|---|---|---|
| Runtime (one renderer, bloom, QA stepping) | ✅ | `src/app/` |
| Login / discipline select (necro theme, portraits) | ✅ | `src/scenes/LoginScene.ts`, `CharacterSelectScene.ts`, `graphics/NecroBackdrop.ts` |
| World: 5 areas, sealed doors, waystones, recall | ✅ | `content/areas.ts`, `content/layout.ts`, `graphics/WorldView.ts`, `gameplay/nav.ts` |
| Authoritative sim: waves, 6 enemy types, elites, corpses, thralls, zones, boss | ✅ tested | `gameplay/sim/` (+ `__tests__/sim.test.ts`) |
| Necromancer kit (5 rites) + per-spell colour identity | ✅ | `gameplay/AbilitySystem.ts`, `content/abilities.ts` (`SPELL_FX`) |
| Progression: XP/gold → server; tiers/shards/unlocks/Ascension → server when `/api/necro-progress` exists, else localStorage | ✅ client + mock; **server side awaits the VPS** | `gameplay/progression.ts`, `gameplay/necroRules.ts`; VPS brief `server/VPS_HANDOFF.md` |
| Loot / Reliquary / Workbench (3 professions) / Rites / Settings | ✅ | `gameplay/loot.ts`, `ui/*Panel.ts` |
| HUD (orbs, slots, upgrades, minimap, target frame, boss bar) | ✅ | `ui/HUD.ts`, `ui/Minimap.ts`, `ui/ui.css` |
| Co-op: instanced worlds, host authority, intents, host migration | ✅ tested live (2 tabs) | `server/realtime/server.js` (+tests), `net/realtime.ts`, `gameplay/sim/snapshot.ts` |
| Audio (procedural WebAudio SFX + ambience + boss drum) | ✅ wired, **not yet ear-tested** | `src/audio/Audio.ts` |
| Art: 4 discipline heroes, base hero, 7 creatures, boss, 16 props, textures, icons, portraits | ✅ | `public/models/`, `public/art/`, records in `art-manifest/` |
| Occlusion cutout, target ring, cursors, attachment auto-calibration | ✅ | `graphics/occlusion.ts`, `ui/cursors.ts`, `graphics/Creature.ts` |
| Production build | ✅ `DEPLOY_BASE=/play/ npx vite build` (mock backend excluded) | `vite.config.ts` |
| Illustrated README / in-game guide | ✅ | `README.md`, `docs/screenshots/` |
| In-game Codex (K), per-character discoveries, onboarding tips (Settings toggle) | ✅ | `ui/CodexPanel.ts`, `content/codex.ts`, `gameplay/codexJournal.ts`, `ui/Onboarding.ts` |
| CI (typecheck, vitest, realtime tests, build on push/PR to master) | ✅ written, first run happens on push | `.github/workflows/ci.yml` |
| Headless balance harness (bot drives the real WorldSim) | ✅ | `gameplay/balance/harness.ts`, `report.ts`, `npm run balance` |
| Combat depth: Corpse Explosion, elite affixes, Grave Surges, Soul Harvest | ✅ in master + QA'd in-browser | `gameplay/sim/WorldSim.ts`, `AbilitySystem.ts`, `HUD.ts` |
| Environment: nave water + puddles, per-area weather, distant silhouettes | ✅ QA'd in-browser (high + low) | `graphics/Water.ts`, `graphics/Atmosphere.ts`, `WorldView.ts`, `content/layout.ts` |
| First balance pass (danger at intended band, tamer Wave Speed) | ✅ harness | `BALANCE.md`, `content/enemies.ts`, `content/areas.ts`, `content/upgrades.ts` |
| Prelate balance (boss harness `npm run balance:boss`, ~95k HP solo) | ✅ harness + guard-rail tests | `gameplay/balance/boss.ts`, `sim/BossBrain.ts` |
| Easy / Medium / Hard difficulty (host-authoritative, in snapshots) | ✅ QA'd | `content/difficulty.ts`, Settings |
| Wave Speed milestones: Elite Vanguard / Restless Crypts / Nightfall | ✅ QA'd | `content/upgrades.ts`, `WorldSim`, HUD dial |
| Grave Surges from mausoleums/sarcophagi | ✅ QA'd | `layout.crypts`, `WorldSim.startSurge` |
| Statuses: Hemorrhage, Chill, Sanctified, Bone Hex, Silenced | ✅ QA'd | `content/statuses.ts`, snapshot flag bits 3/12–15 |
| Thrall variety: archer / bone mage / plague bearer (from the corpse) | ✅ QA'd | `WorldSim.applyExhume`, `EntityViews` |
| Signature rites (lvl 10, key R): Ossuary Wall, Command: Rend, Dirge, Plague Bloom | ✅ QA'd (wall + locked slot in browser; all four sim-tested) | `content/abilities.ts`, `WorldSim.applySignature`, realtime `signature` intent |
| Onboarding: welcome + 12 just-in-time tips, "Show tips again" | ✅ QA'd | `ui/Onboarding.ts` |
| Horde perf: per-area prop batches + shadow LOD (−40% triangles at the cap) | ✅ measured | `WorldView`, `EntityViews.shadowLod`, `__cwDebug.perf()` |
| Relic runes | 📝 server proposal only | `server/proposals/relic-runes.md` |
| **Ascension** (prestige): Altar panel, Ashes, 9 Covenant Boons, +3 levels/rank, snapshot-synced rank | ✅ QA'd (full ascend + boon flow in browser) | `content/ascension.ts`, `progression.ts`, `ui/AscensionPanel.ts` |
| **VPS storage package** (validated `/api/necro-progress/*` routes, MySQL store, schema, shared rules bundle, tests) | ✅ tested with an in-memory store + mock backend; not installed yet | `server/vps-handoff/necro-progress/`, `server/VPS_HANDOFF.md`, `npm run build:server-rules` |
| **Grimoire (L)**: 4 static rite slots, player-chosen from 8 rites; new Wailing Skull / Grave Step / Grave Frost / Bone Mantle (lvl 3/5/7/12); Gemini icons + tintable VFX sprites | ✅ tests + browser QA (2026-09-27) | `gameplay/loadout.ts`, `ui/GrimoirePanel.ts`, `AbilitySystem.ts`, `graphics/fxImages.ts`, `public/art/fx/` |
| **Enemy variety**: Censer Bearer (Incensed aura), Choir Wraith (scream ring), Skull-Rat packs, Bone Golem (3 corpses) + themed **processions**; Tripo models | ✅ tests + browser QA (2026-09-27) | `content/enemies.ts` (`WAVE_THEMES`), `WorldSim`, `EntityViews`, `public/models/{censer_bearer,skull_rat,bone_golem}`, `models/props/choir_wraith.glb` |
| **Professions / gathering**: shared rules + Death Muffin `POST /api/gather` (time budget, server rolls) | ✅ tests + live VPS deployment (2026-09-27) | `gameplay/gatheringRules.ts`, `server/death-muffin/backend/gathering/`, `migrations/002-gathering.sql`, `server/death-muffin/GATHERING_DEPLOY.md` |
| The Sexton's Acre (safe zone west of the Chapterhouse, every node tier, pond, stations) + rich nodes in hunting grounds | ✅ QA'd in-browser | `content/areas.ts`, `content/layout.ts` (`nodes`, `ponds`), `graphics/WorldView.ts`, `Atmosphere.ts` |
| Gathering nodes in the sim (shared depletion, `gather` intent, snapshot `depleted`), loop + Auto, stand-in node views | ✅ sim/loop tests + browser QA | `sim/WorldSim.ts`, `gameplay/Gathering.ts`, `gameplay/gatherPlan.ts`, `graphics/NodeViews.ts`, `nav.findPath` |
| Skills panel (P), node hover card, Bone Kiln / Sawpit / Cooking Fire, 6 counsel tips, Codex Professions tab | ✅ QA'd | `ui/ProfessionsPanel.ts`, `ui/ForgePanel.ts` (stations), `ui/HUD.ts` (`nodeTip`), `ui/Onboarding.ts`, `ui/CodexPanel.ts` |
| Professions G3–G7 | Node art, gardening, processing, Contracts, laborers, capes and pets are in source and published | Skill leaderboards and other long-tail ideas remain proposals; older roadmap status was stale |

## In flight (check before starting overlapping work)

- **Alchemist's Wing (branch `dm/alchemy-wing`, 2026-10-02, not merged/deployed).** Area `alchemist_wing` (x 20-46, z 8-32) through the Chapterhouse's east door (`chapter_wing`, z 17-23); props in `WING_PROPS` (layout.ts, no `rand` use so other areas do not shift); stations: cauldron + alembic open `ForgePanel.open('cauldron')` (alchemy only, brew-of-the-day bonus from `content/wing.ts`), shelf opens `ui/ReagentShelfPanel.ts` ("found" is browser-local). Workbench Alchemy tab keeps working with a hint. Apothecary NPC not placed: use `WING_APOTHECARY_SPOT` (areas.ts). QA: `tools/qa/alchemy-wing-smoke.cjs`. No server change, no migration. Rerun `npm run build:server-rules` after merging (area list is in the generated rules).

### Visible Grave Laborers (branch `dm/laborer-world`, not deployed, client only)

In the Sexton's Acre each assigned laborer (H panel) now stands beside a node of its post and works it. `graphics/LaborerViews.ts` owns it (models and tools load on the first Acre visit, nothing updates outside the Acre); pure rules (node pick, standing spot, clip per skill, hover text) are in `graphics/laborerLayout.ts`. `Creature.loopRange(anim, start, end)` loops a clip segment (thrall `chop` 0.7-3.0 s); `dig` loops whole; fishing is idle with a rod. WorldScene only forwards hooks (`setActive` in `enterArea`, `update`, hover/click, `laborPanel.onView`, `checkLabor`). A gold check marks ready work; hover shows post and time; click opens H. One quiet `audio.play` call site (`LaborerViews.beats`). Smoke: `tools/qa/laborers-smoke.cjs` (port 5325). Needs the thrall GLBs with `dig` and `chop` clips (already in `public/models`).

### Necromancer balance pass (branch `dm/balance-pass`, not deployed)
2026-10-02. Numbers and sim rules only; details and before/after tables in `BALANCE.md` ("Necro pass"). Wave Speed density levels off
after tier 3 (rewards, incl. new XP scaling, keep climbing), Wave Speed ramps in over the first 30 s of a visit, areas with no living player
crumble after 8 s and greet the next arrival afresh, Ossuary/Mourner mods and the Coliseum elite rate tuned, and a harness NaN bug that
froze the bot is fixed. `necro-rules.cjs` was regenerated (bundles `areas.ts`). Guards: `balance-necro.test.ts`. Needs a human playtest of
tiers 6-8 before deploy.

### Inventory relief (branch `dm/inventory`, not deployed)

Bag 24 to 48 slots (`BAG_SLOTS` in `gatheringRules.ts` is the one source; saves send `bagSize`, a server treats a missing one as 24 so a stale tab cannot wipe slots 24-47), the Ossuary Vault (`vault.cjs`, 120 shared slots, key V, migration `017-vault.sql`), Salvaging (`salvage.cjs`, Bone Grinder in the Acre, seventh skill) and Reliquary locks plus Sell all junk. Pure move and yield rules live in `vaultRules.ts` and `salvageRules.ts` and are bundled for the server. **Deploy needs migration 017** (`deploy-release.sh <rev> .../017-vault.sql`). Sexton's Mantle now needs total level 693 (seven skills). Offline-to-online sync does not carry the offline vault. Smoke: `tools/qa/vault-salvage-smoke.cjs`.

### Item level and affixes (branch `dm/affixes`, not deployed; GRIND-LOOP #2)

Gear drops get an **item level** (dropper's level +2 elite, +4 boss, +5 first kill) and **0-3 affixes**, rolled by the server. **Deploy needs migration 020** (`deploy-release.sh <rev> .../020-loot-instances.sql`), the new backend files (`loot.cjs`, `loot-instances.cjs`, `gathering/affix-rules.cjs` and the edited `bag-store.cjs`, `inventory-save.cjs`, `vault.cjs`, `salvage.cjs`, `offline-full-sync.cjs`, `server.js`) and a client build together; the script copies `*.cjs` and `gathering/*.cjs` already.

- **Design.** New table `loot_instances (id, account_id, item_id, ilvl, affixes JSON, created_at)`; `inventory.instance_id` and `account_vault.instance_id` (each UNIQUE, FK `ON DELETE SET NULL`) point at it. A move (equip, belt, Vault, sort) carries the id with the row; the rolled fields are written by exactly two places: `POST /api/loot/roll-gear` (server RNG) and the offline-sync import (re-validated, fresh ids). A bag save can only *name* an instance (`instance_id`): it must exist, belong to the account, match the slot's item, be unique in the payload and not be held by a worn slot, another character or the Vault, or the whole save is refused with a readable 400 and nothing is written. A save that stops naming a piece (a sale) deletes its roll, so it cannot come back. A save with no `instance_id` key at all (a stale tab) keeps the roll already on that slot. Chosen over JSON columns on the rows because the client's bag save replaces whole rows: with columns it would be the one writing the affixes. Plain rows keep `instance_id NULL` and base stats. The name `loot_instances` avoids the legacy Crossworlds `item_instance` table.
- **Routes.** `POST /api/loot/roll-gear { characterId, drops: [{ item_id, level, source }] }` (1-12 drops; `/api/loot/roll` is the old Crossworlds route and still answers `enemyType`). The server clamps `level` to character level +10, caps unclaimed rolls at 300 per account (and forgets unclaimed ones after 2 days). Every inventory/vault/salvage reply rows carry `instance_id`, `ilvl`, `affixes`.
- **Rules.** `src/gameplay/affixRules.ts` (pool of 14: eight stat prefix/suffix pairs plus six necromancer levers: thrall damage and health, essence regeneration, Miasma radius, Withered stacks, ward per thrall; ranges by item level; names; effective rarity by affix count; sell value; validation) bundled to `gathering/affix-rules.cjs` by `npm run build:server-rules`. Affix ids are stored: never rename, only add.
- **Stat pipeline.** Worn affixes add to the same three pipelines set bonuses use (`computeStats` flat stats, discipline `mods` through `WorldScene.applyBoons`); `resolveSetBonuses().totals` is sets + affixes, with `setTotals` / `affixTotals` for attribution. `outfitSignature` makes the scene rebuild the discipline when a worn roll changes.
- **Client.** `net/api.ts` reads rolled rows through `decorateSlot` (full name, rarity by affix count, price). `WorldScene.dropItems` asks `LootRoller` to roll a kill's gear before it lands on the ground (a failed roll leaves plain gear). `window.__cwDebug.dropGear(itemId, level, source, n)` is the QA hook. Tooltips and the detail strip show item level and affix lines (necromancer ones violet, marked with a dagger); the arrows, power score and Character sheet count affixes (sheet has an "Item affixes" block); Codex tab "Item affixes"; counsel tip `affix`; Sell all junk / Salvage all below rare skip pieces with a necromancer affix.
- **Offline.** The mock mirrors the server (registry in the mock account, same refusal rules). The portable save carries each roll inline (`slots[].inst`), `offline-full-sync.cjs` validates it and mints fresh instances on load; the online snapshot carries them back. The offline Vault is still not synced.
- **Not covered / left.** `GET /api/game/equipment` and `/api/character/stats` (Unity-era routes) ignore affixes; the web client computes its own stats. Numbers (ranges, odds, salvage and sell bonuses) are untuned against the balance harness. Co-op partners see no affix names (they only see worn item ids).
- **Tests and QA.** `src/gameplay/__tests__/affixes.test.ts`, `server/death-muffin/backend/loot.test.cjs` and `affix-paths.test.cjs` (fake-connection pattern; `bag-fake-db.cjs` knows `loot_instances`), `tools/qa/affixes-smoke.cjs` (offline UI) and `tools/qa/affix-db-probe.cjs` (real MySQL scratch database plus the real `server.js`: run it before deploying, instructions in its header).

### Armor set bonuses (branch `dm/set-bonuses`, not deployed)

2/4/5-piece bonuses for all 18 sets, client-side only (no server or migration change). Table and wiring in `docs/ARMOR-SETS.md`; data in `src/content/setBonuses.ts`, resolution in `src/gameplay/setBonuses.ts`. Flat stats enter `computeStats`; multipliers/additions fold into the discipline `mods` in `WorldScene.applyBoons` (rebuilt by `refreshStats` when the active set signature changes). `gearStats` re-bases the discipline per outfit (`withSetBonuses`) so verdicts and the gear score count gaining/losing a bonus; mods-only effects are valued in `SET_VALUE`. UI: tooltip tracker, paper-doll `.in-set` glow, Character sheet "Set bonuses", Codex "Armor sets" tab, counsel tip `setBonus`. Tests: `src/gameplay/__tests__/setBonuses.test.ts`; smoke: `tools/qa/set-bonus-smoke.cjs`. Numbers are untuned against the balance harness (it equips no gear).

### Tool belt (branch `dm/tool-belt`, not deployed)

Four reserved inventory slots 110-113 (hatchet, pickaxe, rod, spade; rows are `equipped=1`, `equipped_slot='belt_<kind>'`, so bag saves, crafting, sell, Salvage and the Vault never touch them; no migration). `POST /api/inventory/belt` (`backend/tool-belt.cjs`) moves a tool bag<->belt transactionally (swap needs no space; unbelt with a full bag is refused readably). Gather/AFK read belt + bag (`getBeltTools` in gather-store). `offline-full-sync` accepts 110-113 (tool kind must match the slot). Client: belt row under the paper doll (`src/ui/toolBelt.ts`, `InventoryPanel`), one-time "Belt your best tools?" offer (dismissal in localStorage `dm_belt_offer_<id>`), Skills shows the active tool and where it is, hero's hand tool tinted by metal. Smoke: `tools/qa/tool-belt-smoke.cjs`. Deploy needs no migration, but the server files (`tool-belt.cjs`, `server.js`, gathering/*.cjs) and a client build both go out together.

### 2026-10-01 release and next work

- The frozen candidate passed typecheck, 497 client tests, nine server suites, a production build, and local spell-swap, reagent, Fen and Mire Mother browser checks. Fen performance was 289 calls / 486,775 triangles / 1.849 ms update versus 231 / 485,691 / 1.64 ms in the Graves sample.
- Backup `~/death-muffin/deploy/backup-pre-necro-fen-20261001T171843Z` contains the database dump, old runtime files, index, checksums and `ROLLBACK.sh`. Migrations 013–015 dry-ran in a rolled-back transaction, then applied in order. Both services are active and the public API is healthy. The first post-restart public request briefly returned 502; it recovered before the client index was published. The release script now retries that health check.
- Public index matches the frozen candidate. `live-release-smoke.cjs` passed temporary-account login, co-op, class cards, Grimoire rites and page-error checks; its test account was removed. A normal first-time `/api/character` 404 is expected. The full four-discipline visual audit and subjective audio check remain open.
- A client-only brand correction followed: `index.html` and in-game LoginScene now identify Death Muffin; the old Crossworlds logo is no longer displayed. Local login screenshot and metadata checks passed, and the public index matches `deploy/candidate-brand-20261001`. Prior index is in `deploy/backup-pre-brand-20261001`. The Vite dev API proxy defaults to Death Muffin's `127.0.0.1:5190`; inherited Crossworlds deployment documentation is explicitly historical.
- **Next implementation:** GRIND-LOOP §3 #2, the loot item-level and affix chase. Current loot is client-rolled and bag saves are by item id, so persistent per-item rolls need a server-backed instance path.

### Local release package (2026-09-30)

- Five interrupted Claude worktrees were recovered and merged in the current branch. Brew engine, necromancer weapon line and animations, reagents, and Mourning Fen are integrated. The recovered `tools/qa/necro-audit.cjs` passed a focused Ossuary clip pass with no browser errors; its sampled idle/run/cast/hurt/dig hips showed zero horizontal drift. The full four-discipline visual audit remains open.
- Migrations `013-necro-weapons.sql`, `014-alchemy-reagents.sql`, and `015-fen.sql` are additive and must be applied in order before publishing the corresponding client. Deploy server rules and realtime code with the same release. Use a fresh production build (`npm run build:death-muffin`), verified backup and public smoke as described below.
- The Skills/AFK layout and Settings spacing are local UI edits. WASD was already implemented and browser verified. The Grimoire now lets a player swap any five unlocked class rites, including the right-click slot; visible swap buttons under every rite icon open the selected socket. The level-10 signature remains on R. Saved four-slot preferences gain the original right-click rite as slot five. `tools/qa/spell-swap-smoke.cjs` verifies level gates, swap and reload persistence.
- Player README now names the new systems and distinguishes integrated local content from recorded live releases. The DEV `?offline` mock still exists; there is no downloadable offline player build.

### Historical open threads (2026-09-29)
- **Direction:** the owner wants a continuous reward loop ("addict me to grind"). The plan and backlog are in
  [docs/GRIND-LOOP.md](docs/GRIND-LOOP.md), and every new feature should feed it.
- **2026-09-30 (VPS session, DEPLOYED 03:29 UTC): Cinder Pyre + Cinder Regent, Catacomb Warren, Bone Coliseum, Kill Chain, Milestones, Omens.**
  Commit `edb2237`, tag `stable-20260930-pyre-levels`, built from a pristine `git archive` (never the shared tree) with
  `deploy/deploy-pyre-levels.sh <checkout>`; rollback copies are in `deploy/backup-pre-pyre-20260930-032920` (chronicle.cjs,
  necro-rules.cjs, realtime server.js, index.html). Server files shipped first (new boss id `regent`, area ids), client last.
  Verified through the public edge (health, index.html byte-equal, every new model/texture 200, bundle contains the new
  content) and clean service logs. NOT yet verified: a real login walking the three new doors (Graves west, Ossuary east,
  Cloister east) and the Regent fight live. The armor-set work stayed out of this commit (it is still uncommitted here,
  with migrations 006/007 that need applying before it ships).
- **Plague Cloister: shipped 2026-09-29** (see PHASE_REPORTS → "Plague Cloister"). Level-scaled end zone (min 20;
  `WorldSim.areaLevel` follows the highest-level living player inside), Plague Doctor / Flagellant, the Plague Saint.
  Players now send `level` on join; the realtime server clamps it and `classIndex` (now 0–9; it was 0–4, which showed
  New Blood partners as Rotweavers). **Next:** GRIND-LOOP §3 #2 (loot affix chase) is the biggest remaining hook.
- **Dev access (2026-09-29):** the owner's `Brbmuffins` account now has `gm_enabled = 1` in the live DB (role stays
  `player`, no GM permissions). The client overlay already opened every area, rite and tier. Now the server also
  treats staff as past every area seal: kills count and boss summons work anywhere (shards are still charged), and
  the saved `unlockedAreas` never changes. Everyone else unlocks areas with kills. See `RuleOpts.staff` in
  `necroRules.ts` and `isStaffAccount` in the backend `server.js`. Rollback: `~/death-muffin/deploy/backup-pre-devstaff-*`.
- **Dead loot:** seeds, gems, reliquary fragments and covenant seals drop with no use. Selling now exists; real sinks
  are in GRIND-LOOP §3. `kit_iron_warden` is still an inert consumable.
- **Balance left for owner feel:** Nave geared deaths +15% (Acolytes), Ossuary geared kill rate −18% (burrowed ghouls).
- **Parallel agents:** another agent session also edits this tree. Run `git status` before committing and don't
  sweep someone else's staged work into your commit unreviewed.
- **Deploy recipe:**
  1. `npm run build:death-muffin`.
  2. Back up the live index, server files and any DB tables to `~/death-muffin/deploy/backup-*` with a ROLLBACK.sh.
  3. Copy the rules `.cjs` files, `realtime/server.js` and the necro-progress routes, then restart both services.
  4. Publish `dist/{assets,art,models,fx,audio}`, with `index.html` last.
  5. Run `node tools/qa/live-release-smoke.cjs`.
- **Trust model:** loot, gold and bag saves are client-reported (the server validates ids and stacks). Shards and the
  necro progression are server-ruled (`necroRules.ts`; the area-boss summon is `summonAreaBoss`).

- **2026-09-29: area bosses built (Gravedigger King, Bone Abbess, Drowned Congregation).** See PHASE_REPORTS →
  "Area bosses". Deploying it needs the realtime `server.js` (it validates `summonBoss.boss`) and the regenerated rules.

- **2026-09-29 documentation/help audit:** staged locally. The source README
  and in-game copy now reflect current kits, Easy auto and delivered professions;
  the documentation map distinguishes source, published releases and historical
  plans. Typecheck, 24 focused tests and the local Markdown link audit pass.
  The full client suite's two known failures are listed above.
- **2026-09-29 audio / High-quality graphics pass:** pending visible-browser
  ear-test and any user-provided screenshot of other ground artifacts. The
  existing full client suite has two failures outside this pass:
  `layout-water.test.ts` sees the newly added `drowned_font` inside the nave's
  designed water, and `necroServer.test.ts` reports a stale generated rules
  bundle. Leave those with the concurrent boss/server-rules work owner.

### Historical handoffs — dated records, not today's task queue

- **2026-09-28 VPS session, deployed in two checkpoints** (tags `stable-20260928-flyers`, `stable-20260928-mobs-g6`):
  flyers, rites, backlog mobs, animation variety and Professions G6 are live, and migration 004 is applied. See PHASE_REPORTS.
  Previous note: flying mob pack (gargoyle, moth, bat, seraph),
  Grimoire expansion (Soul Siphon, Bone Prison, Grave Hands, Bone Storm), Bone Mantle bone meshes, and an Easy-auto
  movement fix. Details, numbers and caveats are in PHASE_REPORTS → "Flying pack, Grimoire expansion…".
  - Deploying needs `npm run build:death-muffin` plus the regenerated `necro-rules.cjs`.
  - Optionally deploy the realtime `server.js`, which sanitises the new `root`/`slow` hit flags.
  - Tripo balance is 9,455.

- **Workstation wiring pass: DONE and staged (2026-09-27 late, usage ran low; resume from here).** All tests are
  green: typecheck, 225 client, 33 server and 3 VFX. Checked in the browser with no console errors.
  - **Binbun brightness:** `BINBUN_GAIN = 0.5` plus a soft knee (`bb_out`) in every program
    (`graphics/binbun/shaders.ts`).
  - **Effect presets:** one tuning table, `graphics/binbun/presets.ts` (`FX_PRESETS` + `playFx`), with colours from
    `SPELL_FX`.
  - **Rite hooks** (`AbilitySystem.bb`): Soul Harvest, Exhume, Miasma, Skull (rides the projectile via the new
    `Effects.projectile().pos`), Grave Step, Grave Frost, Corpse Explosion, Litany, Offering, Ivory Cleave (≤2),
    Veil Step, Rally, Carrion Seed.
  - **Scene hooks** (`WorldScene.bb`): Rend, Wall, Dirge, Bloom, toxic/rot pools, Grave Surge, breaches, affixes
    (bell toll, vengeful), boss toll/slam/rain, Choir Wraith scream (via the frame-driven `fxLater` queue), thrall
    rise, level-up, censer incense (follows the bearer), and the toxic-corpse stink.
  - **Loot:** rare/epic Binbun markers and shard glows (`LootView`).
  - **Anti-clutter** (owner: "not too much clutter during combat, performance and smooth zone-out"):
    - Frequent primaries (Needle, Fan, Lance) get **no** Binbun layer; only needle crits do.
    - Cleave and Frost impacts are capped.
    - The whole Binbun layer is **High quality only** (`effects.binbun.enabled`).
  - **Props:** 18 registered in `layout.ts` `PROPS`.
    - The Chapterhouse **Altar of Ascension** and **Rite Niches** are real models now (they replaced two statues).
      The Niches interactable moved to (-10.8, 26.5).
    - A new **Covenant Lectern** interactable (kind `lectern`, Acre spawn) opens the Codex.
    - `DRESSING` + `dressRooms()` places room props **after** the seeded layout, so no grave or node moves. 21 of 28
      found a clear spot; the rest skip on purpose, which also keeps rooms uncluttered.
    - `WorldView` has a generic fallback block for new props.
  - `necro-rules.cjs` and `gathering-rules.cjs` were regenerated (`areas.ts` changed), so re-install them on the
    VPS with the next deploy.
  - **Next, in order:**
    1. Interactable beacons + nameplates + **E** to interact + minimap icons, and the ambient-fire manager (brief §6;
       presets for `interact_rim`, `altar_beacon`, `brazier_fire`… exist in `presets.ts`). Keep the ambient loopers
       under ~14 so spells keep headroom (the runtime caps loopers at 32).
    2. A co-op **cast echo** (cosmetic relay so partners see each other's direct casts; today only host-event
       spells are visible to the partner).
    3. Mobs brief → bosses → aspects → First Rites → runes → world-dressing leftovers → new classes.
  - The boss props (`kings_grave`, `abbess_reliquary`, `drowned_font`, `skull_niche`) are registered but not
    placed; the area-bosses brief places them.
- **2026-09-27 late: the cloud agent is PAUSED; the workstation session is wiring the whole queue below into one working build** (owner: "wire everything up as much as possible into a working product"). Local `master` was fast-forwarded to the agent's `964906f`; the workstation's work is staged on top (backup ref `refs/backup/ws-staged-20260927`). Queue, in order:
  1. finish [`spell-variety-first-session.md`](docs/agent-briefs/spell-variety-first-session.md). Done on
     `claude/adoring-knuth-hd1uox`: §2 dev access (`55a6dd2`), §3 Grimoire + LMB primary (`7c3afae`), §4 seven rites
     (`502f726`), §5 **runtime + DEV gallery** (this session's last commit). **Next, in order:**
     - §5 wiring, additive (today's effects stay): start with the new rites in `WorldScene`'s event handlers
       (`bone_fan_hit` / `ivory_cleave_hit` with `once: true`, `grave_offering_orb`+`_ripple`, `rally_area`,
       `rally_thrall_rim` via `follow`, `carrion_seed_armed` (follow the corpse; kill on `seedGone`) / `_burst`,
       `rot_lance_projectile` + `veil_step_trail` with `duration`), colours from `SPELL_FX`. Call
       `effects.binbun.spawn(id, {...})`; it never throws or waits.
     - Tune per effect in the gallery first: `__cwDebug.vfxGallery(0..3)` in `?offline`, or `vfx(id)` one at a time.
       First headless look: all 60 spawnable effects render without shader errors, but `dirge_area`, `exhume_lift`
       and `prelate_impact` read blown out under bloom. Check `uGain` / emission in `src/graphics/binbun/shaders.ts`
       and the per-pack shaders (they go through the approximate `generic` program).
     - Then §6 interactables (beacons use `interact_rim`), §7 First Rites, §10 docs;
  2. [`mobs-barrow-ghoul-lich-acolyte.md`](docs/agent-briefs/mobs-barrow-ghoul-lich-acolyte.md) (+ §5: the Bell-Sworn
     Templar);
  3. [`area-bosses.md`](docs/agent-briefs/area-bosses.md);
  4. [`build-depth-aspects-runes.md`](docs/agent-briefs/build-depth-aspects-runes.md) (+ §7: the Bone Colossus model). Its
     runes need Death Muffin migration 003 plus a deploy;
  5. [`world-dressing.md`](docs/agent-briefs/world-dressing.md) (can slot in anywhere);
  6. [`new-classes.md`](docs/agent-briefs/new-classes.md): the class framework, then Hollow Knight first.

  All their art is staged on `master`. Tripo balance is now 20; top up before any new 3D work.
- **UI readability pass (workstation, staged on `master`):** `src/theme/tokens.css` and a new `src/ui/readability.css`
  (linked in `index.html` after `ui.css`). Future UI tweaks go in `readability.css` (or `ui.css`), and `readability.css`
  wins on equal specificity. See PHASE_REPORTS.
- **Two new mobs (brief ready 2026-09-27 evening):**
  [`docs/agent-briefs/mobs-barrow-ghoul-lich-acolyte.md`](docs/agent-briefs/mobs-barrow-ghoul-lich-acolyte.md).
  - **Barrow Ghoul:** a new Tripo model (145 credits), `public/models/barrow_ghoul/`. It burrows, erupts in a
    telegraphed ring and gives the Hollow Graves its first new mob.
  - **Lich Acolyte:** the existing model. It raises your fallen thralls against you in the Nave and the Sanctum.

  Cloud code work; the art is staged on `master`.
- **Spell variety + dev access + Binbun runtime + first-session readability (brief ready 2026-09-27 evening).**
  The owner couldn't find where to swap rites; the Grimoire exists (L) but is hidden and gated at levels 3–12. They
  asked for:
  - more rites;
  - full access for their `brbmuffins` dev account;
  - the Godot/Binbun VFX, including world effects;
  - interactables (the Altar and similar) that a first-time player can't miss.

  The cloud agent builds from
  [`docs/agent-briefs/spell-variety-first-session.md`](docs/agent-briefs/spell-variety-first-session.md). The
  workstation has staged on `master`:
  - 45 more Binbun conversions (67 total, including seven `world_*` shader kits);
  - five tintable rite sprites (`public/art/fx/`, `gemini-jobs/spells-v5.json`).

  The rite icons already existed. The owner pushes `master` via GitHub Desktop; the agent merges `origin/master`
  into its branch first.

- **BinbunVFX → Three.js port: conversion done (workstation), runtime done (cloud, 2026-09-27 late), wiring next.**
  Read [`docs/BINBUN-VFX-PORT.md`](docs/BINBUN-VFX-PORT.md). The workstation owns the Godot side
  (`tools/binbun-port.mjs`, `public/fx/binbun/*`, `art-manifest/binbun-*.json`). The cloud agent doesn't edit those,
  and the runtime reads the JSON as-is. Runtime: `src/graphics/binbun/`.
  - `godot.ts`: pure resolver, turns scene JSON into node, material, particle and animation templates.
  - `textures.ts`: procedural stand-ins for the noise/gradient `.tres` the converter leaves unbaked. When the
    converter bakes them, the PNG path wins automatically.
  - `shaders.ts`: exact GLSL ports of the shared `transparent` / `particle` / `glow_fresnel`, plus a `generic`
    program for every per-pack shader (a follow-up is to port those exactly).
  - `BinbunFX.ts`: `effects.binbun.spawn(id, {x, y, z, scale, rot, colors, follow, duration, once, alpha})`, fetch +
    cache, fail-open, capped at 24 one-shots / 32 loopers, pooled, loopers culled beyond 40 m or off-screen, lights
    through `Effects.lightFlash`.
  - `catalog.ts`: impacts, loopers, one-shots and world kits (a test keeps it in sync with the manifest).
  - `gallery.ts`: DEV review grid.

  Rules unchanged: additive only, recolour from `SPELL_FX`, no PointLights, no visual replaced before gallery +
  readability + dense-wave perf QA. The `world_*` kits are not ported yet.

**Professions / gathering: G0, G1, G2 and G4 are built** on `claude/adoring-knuth-hd1uox` (one session, one branch,
not the per-brief `cloud/professions-g*` branches). **G3 art has landed** (workstation, 2026-09-27): the node GLBs are
live as `models/props/prop_node_<model>.glb` (trees, stump, seams, geode, rubble, all four grave tiers, Bone Kiln), and
the seam/geode vein colour stays a code-built emissive overlay. Item icons need no `icon` field, because inventory and
loot load `art/items/<id>.png` by name. Art that exists but has no code yet (stations, garden stages, tools, tool-tier
icons, herbs, planks, meals, skills) is listed in [`docs/ART-BACKLOG.md`](docs/ART-BACKLOG.md). **Wire it; don't make stand-ins.** Next are G5 (Grave Gardening: plots, seeds, tree
patches; `seed_mourning_moss` already drops) and G6 (recipes for the new logs, fish, bones → bone meal, gems). Owner
decisions assumed are listed in `server/death-muffin/GATHERING_DEPLOY.md`. Brief status: [`docs/agent-briefs/README.md`](docs/agent-briefs/README.md).

The three older agent briefs in [`docs/agent-briefs/`](docs/agent-briefs/README.md) are done:

| Brief | Where it landed |
|---|---|
| Combat depth (`cloud/combat-depth`) | Folded into master in `08c62b0`; browser-QA'd 2026-09-26. |
| Environment (`cloud/environment`) | The branch never reached GitHub, so it was rebuilt from the brief on the cloud branch `claude/adoring-knuth-hd1uox` (`5e5e382`). |
| Codex + onboarding + CI (`cloud/codex-onboarding`) | Folded into master earlier. |

**Cloud-session branch:** `claude/adoring-knuth-hd1uox` carries the environment work, the balance
pass and these doc updates on top of master `08c62b0`. Cloud sessions commit and push (they have
no GitHub Desktop). Merge it through GitHub, or pull it into GitHub Desktop.

**Folding a finished local branch into master without committing** (this matches the
stage-don't-commit rule): `git diff --binary <base> <branch> > x.patch && git apply --3way x.patch`.
Run it from bash; PowerShell pipes rewrite line endings and corrupt the patch. `git merge`
refuses while the index has staged changes.

## Historical follow-ups from 2026-09-26/27

These notes explain earlier decisions. Several deployments and queue items below
have since happened; verify against **Current state**, the VPS deployment handoff
and source before acting on them.

**Needs the user (can't be done from a cloud container):**
1. **Ear-test audio** in a visible browser (volumes, ambience crossfades, boss drum loop).
2. **Server storage for progression.** Hand `server/VPS_HANDOFF.md` to a Claude Code session on the
   VPS. It installs `server/vps-handoff/necro-progress/` (additive routes + one new table) after
   recon and backups. The client already switches to it on its own: `Progression.connect()` falls
   back to localStorage on a 404, and on the first successful connect it uploads the browser save once,
   after which the server's copy wins. The web client from this branch has to be deployed too.
3. **Deploy.** Realtime protocol v2 and the client must ship together (`server/realtime/DEPLOY.md`,
   `server/web-deploy/`). The user runs the scripts.
4. **A human playtest of the new balance.** The bot is an upper bound on efficiency and never
   dodges. Report how intended/push feel, and see "Open issues" in `BALANCE.md`.

**From the 2026-09-27 session (needs the user / a deploy):**
- **Commit + push `master` through GitHub Desktop.** Everything is combined and staged on `master`: the professions
  commit (fast-forward) plus all workstation work restored from GitHub Desktop's two branch-switch stashes. Safety refs
  `backup/art-batch-stash` and `backup/art-late-stash` hold those stashes. Delete them (and the two stash entries)
  once the push is confirmed. `cloud/*` and `worktree-agent-*` branches are older work already folded into master, and
  `origin/CrossWorldsWEB` is the July-era README/audit branch, deliberately not merged. This shell can't reach GitHub
  (no stored credentials), so fetch and push from GitHub Desktop. The VPS has its own deploy key.
- **Deploy realtime with the client.** The realtime server gained `signature` sig `mantle` (Bone Mantle) and a
  sanitised `hit.chill` flag (`deploy-realtime.sh` is re-embedded). An older realtime server drops Bone
  Mantle for co-op **guests** (hosts and solo play are fine), and Grave Frost's chill passes through unsanitised.
- `necro-rules.cjs` was regenerated (it embeds `areas.ts`, whose rosters changed). Re-install it if the
  necro-progress package is already on the VPS.
- Ear-test the four new rite sounds (`wail`, `bloodStep`, `frost`, `mantle`) and the look of the new mobs in a visible browser.
- Tripo spent this session (owner-approved; ledger in `docs/ART-BACKLOG.md` §5): the enemy pack (395), 14 node props
  (700), the hero `attack` clip ×5 (50), and the roadmap batch (tools, thrall gear, wraith thrall, 13 more profession
  props, Lich Acolyte, three bosses, five class heroes). `NodeViews` gained `live` models for Blackthorn, Ghostwood,
  crypt collapse and barrow tomb (data only). Node props keep the `prop_` prefix at build time (`tools/build-characters.mjs`).
- **Workload split:** cloud agents build code; the workstation (the only machine with `.ai-keys.local`) does
  Gemini/Tripo work and tracks it in `docs/ART-BACKLOG.md`. Signature-rite icons and the dedicated Corpse Explosion icon are wired (`abilities.ts`; the HUD's
  hue-rotate hack was removed from `ui.css`).
- **Merge fix (PR #4 spell cards × Grimoire):** the cards' listeners are now bound in `HUD.bindSlots()`,
  so they survive the slot rebuild a Grimoire swap does (before this, cards stopped opening after any swap).
  Native `title`s are gone (the cards replace them). `spellTooltip` covers the four new rites, shows the
  rite's actual loadout key and locks by `unlockLevel`.
- `docs/SPELL-VARIETY-PLAN.md` (VPS session, PR #4) was written before the Grimoire shipped. Its loadout
  proposal (role-locked slots), Bone Mantle and Frost Wake overlap what now exists. Reconcile it with
  `GRIMOIRE` before anyone builds from it.

**From the professions build (needs the user / a deploy):**
- **Deploy gathering to Death Muffin:** follow `server/death-muffin/GATHERING_DEPLOY.md` (backup, check the professions
  column type, migration 002, copy `backend/gathering/` + `server.js`, restart the auth service, verify, publish the client).
  `POST /api/professions/award-xp` now answers 410; nothing in the client used it.
- **Realtime:** a new `gather` intent (validated, `successes` clamped to 1–3; `deploy-realtime.sh` re-embedded). An older
  realtime server drops it, so guests' node depletion stays local until it's deployed.
- **Workbench fix, worth deploying soon:** the live `/api/craft` replies with the result, not the bag, and the old client
  kept the pre-craft bag, so the next full-bag save could write spent ingredients back. `ForgePanel` now re-reads the
  inventory and professions after every craft. The offline mock also served `/api/recipes` only with a token, which left
  the Workbench empty offline; fixed.
- **Owner decisions (roadmap §12)** are still open. The code defaults to the live XP rule (`XP_CURVE = 'live'`), optional
  tools, no character XP from gathering, cap 99, and shared depletion with per-player rewards.

**Buildable next (code-only):**
5. **Replay depth, continued.** Ascension shipped. Next from `FUTURE_CONTENT.md` → "Replay & endgame
   depth": daily rites (date-seeded objectives paying Ashes), discipline talents (levels 5/15/20), weekly
   omens, Prelate Echoes per rank. Rank/Ashes/boons are already part of the VPS storage package.
   Any new persistent field has to go through `necroRules.ts`, followed by `npm run build:server-rules` and
   a re-install on the VPS.
6. **Co-op session dashboard** (user request). Easy/Medium/Hard is the first slice. The rest (Wave
   Speed, HP/damage, density, elites, surges, arrival wave, roster weights) becomes a host panel
   relaying a validated `tuning` field. Spec: `FUTURE_CONTENT.md` → "Co-op session dashboard".
7. **Art for new content** (needs the Gemini/Tripo keys on the workstation, `ASSET_PIPELINE.md`):
   icons for the four signature rites and Chill/Silenced (currently retinted or inline-SVG
   placeholders), and real bow/staff models for archer and bone-mage thralls.
8. **Discipline balance.** Gravecaller is the weakest under pressure and Ossuary swings the most
   (`BALANCE.md`). Signature rites and thrall variety aren't in the farming bot yet, so add them to
   `harness.ts` before tuning.
9. **Realtime deploy note:** protocol additions this session are `signature` intents, `hit.bleed`,
   and snapshot `difficulty` plus new flag bits. Older clients ignore them, but ship client and
   realtime together (`server/realtime/DEPLOY.md`; `deploy-realtime.sh` is already re-embedded).

## Gotchas that cost time before

- `npm`/`node` may not be on the desktop app's PATH → `.claude/launch.json` calls `node.exe` directly;
  in a PowerShell tool shell prefix `$env:Path = "C:\Program Files\nodejs;$env:Path";` and call
  `node node_modules/typescript/bin/tsc --noEmit`, `node node_modules/vitest/vitest.mjs run`, etc.
- Never `git add -A` while agent worktrees exist unless `.claude/worktrees/` is ignored. It
  stages them as embedded-repo gitlinks, which gives the cloud clone broken submodules.
- Tripo v3 retarget **batch** mode concatenates clips into one — always `animationMode: "single"`.
- Tripo PBR materials are mostly metallic → keep emissive boosts ≤0.15 or models white-out under bloom.
- Some original repo files have CRLF line endings — string-replace patch scripts must normalise.
- After editing `server/realtime/server.js` run `node tools/embed-realtime.mjs` (the deploy script embeds it).
- Don't toggle light `visible` at runtime (changes shader light counts → recompiles/hitches).
- sharp holds file handles on Windows — read into a Buffer before overwriting in place.
- `npm run test:server` fails with `Cannot find module 'dotenv'` on a fresh clone. Run
  `cd server/realtime && npm ci` first (CI already does this).
- Headless QA in a cloud container: global Playwright + `--use-angle=swiftshader`. Drive time with
  `__cwDebug.advance()`, and call `unlockAll()` before `goto()` into a locked area (otherwise
  `goto` leaves you at the sealed gate). Seed `localStorage.cw_settings_v1 = {"tips":false}` to hide
  onboarding cards in screenshots.
- `src/gameplay/necroRules.ts` is bundled into `server/vps-handoff/necro-progress/necro-rules.cjs`.
  After editing it (or anything it imports, e.g. `content/upgrades.ts`, `content/ascension.ts`, `content/areas.ts`),
  run `npm run build:server-rules`. The parity test in `necroServer.test.ts` fails if the bundle is stale.
- Water/decal layering: water renders at renderOrder 1, and Effects decals (telegraphs) at 2. Keep
  that order or telegraphs sink under the nave's flood.
- **Windows checkout = CRLF working tree** (`core.autocrlf=true`). Git Bash's `grep -c $'\r'` reports 0 even
  on CRLF files, so check with Node. Scripted string edits must match `\r\n`. The rules-bundle parity test
  now compares with line endings normalised.
- The Gemini tool's `post.lumaAlpha` + `post.mask` turn white-on-black art into tintable VFX sprites
  (`ASSET_PIPELINE.md` §1). A rig-less Tripo model builds as a **prop** GLB (`models/props/<id>.glb`), so
  register a static creature (the Choir Wraith) with that URL in `modelPaths.ts`.
- Another session may hold port 5188; `.claude/launch.json` has `death-muffin-web-alt` on 5198.
- A long-running Vite dev server on this Windows drive can **serve stale modules** after edits (the watcher
  misses changes). If behaviour doesn't match the source, `fetch('/src/…')` in the page to confirm, then restart the preview.
