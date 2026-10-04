# Evaluation: Majid Manzarpour's Three.js skills and VFX repos

Date 2026-10-02, branch `dm/skills-eval`. Evaluation only: nothing was installed, `~/.claude` was not touched, no game code changed.
Source clones were read-only (`git clone --depth 1`) into a scratch directory outside the repo. Everything below was read from those clones;
nothing was run (no scripts executed, no network calls, no keys used).

Question from the owner: "there are other skills in his repo that could be good for us?"

**Short answer.** Yes, but as a *reference library*, not as an install. The nine skills are written to build a game from an empty folder.
We have a mature game, our own pipelines and our own rules. What is worth taking is concentrated in four files (`technical-art.md`,
`shader-cookbook.md`, `visual-scorecard.md` + the canvas inspector's pixel metrics, `playtest-bot.md`) plus a handful of Tripo rigging/animation facts.
`threejs-vfx` is a very impressive sandbox but a poor drop-in: it is a 358-file JavaScript app with its own runtime, a mismatched copyright line and
bundled third-party assets; treat it as a technique library.

## 1. Our baseline (what the skills are compared against)

From `CLAUDE.md`, `ASSET_PIPELINE.md`, `docs/BLENDER-AUDIT.md`, `tools/qa/README.md` and the source:

| Area | What we already have |
| --- | --- |
| Asset generation | `tools/ai/gemini.mjs` and `tools/ai/tripo.mjs` (resumable, `state.json` per task, manifests in `art-manifest/`, spend report, `--yes` gate, keys from gitignored `.ai-keys.local`) |
| Animation / rigs | Tripo v1.0 biped + v2.5 quadruped presets, `tools/blender/` (retarget, rigfix, cleanup, foot-lock), `inPlaceAnimation.ts` |
| QA | ~70 Playwright smokes in `tools/qa/`, `run-all.mjs` (one Vite, per-script process group, retry once, flaky/broken), `__cwDebug` hooks (`advance`, `counts`, `vfx`, `cast`, ...), `qa-common.cjs` helpers |
| Perf | `docs/BLENDER-AUDIT.md` with exact tris, draw calls and texture MB from `renderer.info`; `tools/qa/scene-*.cjs`, `fixed-fight-perf.cjs`; ROADMAP "Performance phase 1" |
| Render pipeline | `GameRuntime.ts`: ACES, exposure 1.2, `UnrealBloomPass` + `OutputPass`, DPR cap by quality, shadow toggle by quality. `WorldScene.ts:696`: `RoomEnvironment` PMREM. Custom `onBeforeCompile` patches with `customProgramCacheKey` already in `friendRim.ts`, `occlusion.ts`, `gearTint.ts`, `wingFlap.ts`, `Water.ts` |
| VFX | `Effects.ts` (CPU ring-buffer particles, one `Points` draw per blend mode), `binbun/` Godot-VFX runtime (67 converted effects), `necroFx.ts` motif layer, `SPELL_FX` colour meanings, `hitstop.ts`, `knockback.ts` |
| Mobile | `src/ui/mobile.css`, `mobile-shots.cjs`, `mobile-nav-smoke.cjs` |
| Balance | `npm run balance*` harness |

Three.js in the repo is **0.166.1**. The skills target **r184+** and `threejs-vfx` targets **0.185**. Cookbook snippets must be checked against 0.166 before use
(`scene.environmentIntensity`, which the cookbook uses, exists since r163 so it is fine; `RoomEnvironment()` with no args is fine too).

## 2. `threejs-game-skills` (MIT, Copyright 2026 Majid Manzarpour, 1.7 MB, 9 skills)

Layout: each skill is `SKILL.md` (2-10 KB) plus `references/` and sometimes `scripts/`. Frontmatter is just `name` and `description` (no hooks, no `allowed-tools`).
`agents/openai.yaml` files are Codex-only and irrelevant to us. The bundled scaffold lives under `threejs-gameplay-systems/assets/threejs-vite-game/`.

### Per-skill verdicts

| Skill | What it actually contains | Quality | Overlap with us | Verdict |
| --- | --- | --- | --- | --- |
| `threejs-game-director` | Router/orchestrator prose; scope rules ("user's words set the bar"); 10-category premium bar; `probe_asset_credentials.sh` (sources the user's `.zshrc`/`.bashrc` and prints KEY=SET/MISSING); `check_evidence.py` (manifest checker); `evidence-manifest.md`; `asset-recovery.md` (failure classification table); `workflow-evaluations.md` (pack self-test) | Well written, but it is a *process* skill for greenfield builds | High: we have CLAUDE.md/ROADMAP/HANDOFF flow, our own approval rules. Its scaffold assumption and "do not end the turn with an offer" rules conflict with how we work (stage-don't-commit, owner approval) | **Skip as a skill.** Steal two ideas: the `asset-recovery.md` table (never re-submit a paid task after an uncertain POST) and the evidence-manifest concept |
| `threejs-gameplay-systems` | Design-brief template; `create_threejs_game.py` scaffold (Vite+TS+Three, `Game.ts` with test hooks, seeded RNG); `game-feel.md` (tween helper, trauma shake, hitstop, squash, FOV punch, pickup pop, rumble); `genre-design.md`; `physics-engine-selection.md` (Rapier) | Competent, generic. Game-feel code is clean and copy-pasteable | Mostly covered: `hitstop.ts`, `knockback.ts`, `CameraRig.ts`, our own feel passes (`NECRO-SPELL-FEEL.md`). Scaffold and physics advice irrelevant to an existing ARPG | **Skip** (small adopt-parts: compare `game-feel.md` "trauma^2" shake and "scale gameplay delta, never the render loop" against `CameraRig.ts`/`hitstop.ts` the next time feel is tuned) |
| `threejs-aaa-graphics-builder` | `visual-scorecard.md` (10 categories, anchors, thresholds, automatic failures); `technical-art.md` (render budget table, material roles, VFX rules, instancing/LOD, imported-asset cleanup); `shader-cookbook.md` (PBR recipes, glass real vs fake, 4 `onBeforeCompile` patterns, sky dome, post chain, cheap tricks); `authoring-recipes.md` (procedural modelling, lighting stack, post rules); 3 anchor JPGs | **Best part of the pack.** Concrete numbers, costs stated per recipe, "Read" rule per effect | Partial: we already have env map, ACES, bloom, cache-keyed patches. We lack a *written* budget table, a visual scorecard, and several recipes (dissolve, scrolling emissive, fake glass, vertex-colour AO, matcap props, fake contact shadow) | **Adopt parts** (top priority, see section 3) |
| `threejs-game-ui-designer` | `ui-patterns.md`: HUD zones, menus, touch controls (pointercancel/lostpointercapture/blur), responsive rules, "web-page defaults to avoid" list | Sensible, generic | Covered by `mobile.css`, `mobile-nav-smoke`, Onboarding rules in CLAUDE.md, owner's "WoW-addon-easy UI" principle (which is more specific) | **Skip.** Only reuse the touch-control checklist if a new touch control is added |
| `threejs-debug-profiler` | `debug-playbook.md`: triage order for blank canvas, loading, loop, input; profiling order; optimisation list "roughly in order of payoff"; `__THREE_GAME_DIAGNOSTICS__` shape | Correct but textbook | We already have `renderer.info` capture in `scene-categories.cjs`, a real audit in BLENDER-AUDIT, `__cwDebug.counts()` | **Skip** |
| `threejs-qa-release` | `inspect-threejs-canvas.mjs` (Playwright; manifest of viewport x state captures; pixel metrics; `renderer.info` vs budget; GPU-vs-SwiftShader detection; error counts); `playtest-bot.md` (+ template spec); `visual-test-harness.md` (determinism contract, baselines, motion evidence); `release-checks.md` (traps list) | Good. The inspector is a single 25 KB dependency-light script | Partial: our smokes check behaviour, not *picture quality*; we have no pixel metrics, no visual baselines, no bot playtest with softlock detection | **Adopt parts**: port the `computePixelMetrics` function and the manifest idea into `tools/qa/`; do not install the skill |
| `threejs-3d-generator` | `threejs_3d_asset.py` (72 KB Tripo CLI: text/image/postprocess/character-pipeline/resume/status/download/`validate-rig`/`validate-animation`); `api-notes.md` (measured API behaviour); `threejs-integration.md` (clip naming, in-place conversion, FBX quirks) | High: hard-won Tripo facts with rationale | Large: `tools/ai/tripo.mjs` already does the same pipeline (resumable, manifests). It lacks `validate-rig` / `validate-animation` and may contradict some of the skill's "never do this" rules (see 3.5) | **Skip install; Adopt parts as reading material** (the notes and the two validators) |
| `threejs-image-generator` | `generate_image.py` (Gemini via `google-genai`, run with `uv`); prompts guidance | Fine | Complete overlap with `tools/ai/gemini.mjs`, which already has `lumaAlpha`, masks, refs, crop, manifests | **Skip** |
| `threejs-audio-generator` | `threejs_audio_asset.py` (ElevenLabs SFX/music/TTS/voice convert); `audio-workflows.md` (audio matrix, Web Audio manager, failure modes) | Fine | We have no ElevenLabs tooling (`tools/audio/` builds samples; sources documented in `docs/AUDIO-SOURCES.md`). Would be a *new paid provider* | **Skip for now.** Revisit only if the owner wants generated SFX/ambience; the audio-matrix idea is the useful part |

## 3. What to take: concrete, with where it applies

### 3.1 Render budget table (`technical-art.md`)

> "Starting contracts, not universal limits. Measure on the target game; document every deliberate overrun as a tradeoff."

| Metric (worst active-play view) | Desktop | Mobile |
| --- | --- | --- |
| Draw calls | <= 300 | <= 150 |
| Triangles | <= 750k | <= 300k |
| Geometries | <= 300 | <= 200 |
| Textures | <= 60 | <= 40 |
| Texture memory (est.) | <= 256 MB | <= 128 MB |
| Shadow-casting lights | <= 2 | 1 |
| Shadow map | <= 2048 | <= 1024 |
| DPR cap | 2 | 1.5-2 |
| Post passes beyond render+output | <= 2 | 0-1 |

Compare with our measured numbers (BLENDER-AUDIT): nave fight on High is **332 calls, 804k tris, ~488 MB decoded texture, 313 textures**. That is over every desktop
row except calls (borderline), and several times over the mobile rows. This is the first time we get a *target* to size the "Performance phase 1" roadmap against, and
it independently supports the audit's findings (props are 65% of tris, decals dominate calls, texture memory is the phone risk).
Apply in: a `budget` constant file next to `tools/qa/scene-categories.cjs` that fails or warns per tier; `GameRuntime.ts` quality tiers (Low = mobile row).

Also quotable and directly actionable:
- "Where to spend: draw calls go to instanced or material-merged repeats; ... unique material count grows faster than geometry count, so share roles aggressively; real shadows go to hero objects and grounding anchors, with blob/contact meshes for small repeated props." (matches audit findings 2-4; apply in `PropBatch`, `EntityViews`, `Effects.ts` decal layer)
- "Instancing is not free: different materials or constantly changing transforms erase the win." (guard for the decal-batching work)
- "Recompute bounds for instanced groups when transforms move materially" and per-chunk batches (audit finding 2: spatial chunking of `PropBatch`).
- "The composer allocates full-resolution HDR targets, so cost scales with DPR^2. Cap DPR before adding passes. On low-end, skip the composer ... or `composer.setPixelRatio(Math.min(devicePixelRatio, 1.25))`." Apply in `GameRuntime.ts` (Low tier: bloom at reduced ratio or off).
- "When performance drops, cut post and shadow cost first, then cull/LOD/instance, then reduce asset density where it is least visible." (ordering for the perf phase)

### 3.2 Visual scorecard + measured pixel metrics (`visual-scorecard.md`, inspector)

The scorecard is 10 categories (art direction, hero, enemies, rewards, world, materials, lighting, VFX, UI, performance evidence) scored 0-3 with calibration anchors and
"automatic failures" (for example "Fog, darkness, bloom, or particles are standing in for missing authored geometry"). Useful as the rubric for our recurring zone-polish audits
(`docs/ZONE-POLISH-AUDIT.md`), which currently use free-form notes.

The inspector's measured metrics are the cheap, scriptable part:

> `colorEntropyBits` below ~3.0, or `dominantColorShare` above ~0.6 - sparse flat scene. `edgeDensity` below ~0.04 - primitive-dominant or empty framing.
> `luminance.contrast` below ~60 - fog/darkness compression.

The function (`computePixelMetrics`, ~60 lines: 160x90 luminance grid, 16-level-per-channel colour histogram, p5/p95 contrast, gradient-threshold edge density) needs only `pngjs`.
**Caveat:** the thresholds are tuned for bright arcade games. A dark-fantasy ARPG will legitimately sit at low `luminance.contrast` and high `dominantColorShare`
(near-black ground). Do not adopt the thresholds; record baselines per zone from our current screenshots and flag *regressions* (a drop of N% from that zone's own baseline).
Apply in: a new `tools/qa/lib/pixel-metrics.cjs` used by `zone-tour.cjs`, `mobile-shots.cjs`, `spell-feel-smoke.cjs`. It would have caught "scene went flat after the lighting change" classes of bug that behavioural smokes cannot.

### 3.3 Shader / material cookbook (`shader-cookbook.md`)

Best items for us (each lists When / Cost / Read, which is the right way to document a shader):

| Recipe | Why it fits Death Muffin | Where |
| --- | --- | --- |
| **Dissolve / spawn** (hash threshold + `discard` + hot edge, `uProgress`) | Corpse fade, thrall rise/despawn, enemy death: currently corpses are full skinned clones (audit finding 4); a dissolve could shorten their life and hide pops. Note its stated cost: `discard` kills early-Z, keep to dying objects only | new `dissolve.ts` beside `friendRim.ts` (same chained `onBeforeCompile` + `customProgramCacheKey` pattern) |
| **Fresnel rim** | Already done as `friendRim.ts`; confirms our approach, including the cache-key rule ("without it three can hand back a cached program ... silently dropping your code") | none, just validation |
| **Scrolling emissive panels** | Rune circles, Bell Sanctum conduits, Alchemist Wing apparatus | `NodeViews.ts`, wall props |
| **Wind sway on instanced foliage** (`instanceMatrix[3]` phase, `h = max(position.y,0)`) | Mourning Fen reeds, Drowned Nave banners/cobwebs; free on `InstancedMesh` | prop batches |
| **Fake glass** (opacity 0.25, clearcoat, `depthWrite:false`) vs transmission | Potion vials, reliquaries, alchemy glassware: transmission re-renders the scene per material and must never go on repeated props | Alchemist's Wing props |
| **Cheap contact shadow** (radial `CanvasTexture` plane, alpha by height) | Floating things (wisps, flyers, loot beams) without shadow-map cost; supports the "real shadows for hero/anchors only" rule | `Effects.ts`, `LootView.ts` |
| **Vertex-colour AO** baked into static props | Zero draw-call grounding for pillars/statues; fits our `tools/blender/` bake step (could be a `recipes/` step) | `tools/blender/` |
| **Matcap props** | Far/background props where lights never matter; cheapest lit-looking material (relevant to texture-memory pressure) | distant prop kinds only |
| **Post chain rules** ("bloom sells authored emissive ... if a shape only reads because it glows, the geometry is missing"; bloom threshold 0.85, strength 0.35-0.6) | Our bloom settings in `GameRuntime.ts` are not documented against any rule; use as the reference when tuning Low/High | `GameRuntime.ts:64` |

Not needed: gradient sky dome (we have `NecroBackdrop.ts`, `Atmosphere.ts`), PBR recipe list (our assets are Tripo textures, not procedural), `RoomEnvironment` setup (already in `WorldScene.ts`).

### 3.4 Bot playtest (`playtest-bot.md`)

Metrics worth stealing: `softlockWindows` ("sampling windows where frames advanced but held input produced neither motion nor progress"), time-to-first-fail, and
"run the bot at two skill levels (reaction delay 0 ms vs 300 ms) and compare survival; if the delayed bot survives as long as the fast one, difficulty pressure is decorative".
We have a balance harness (analytic) and first-hour smokes, but nothing that drives the *real input path* and detects stuck states. A `tools/qa/bot-playtest.cjs` using `__cwDebug` for setup
but real keyboard events for movement would catch nav/geometry softlocks (relevant to the "prop clipping" items in the zone-polish audit). Headless caveats in that file also match
ours: SwiftShader FPS is "fiction" (we already say this in BLENDER-AUDIT).

### 3.5 Tripo facts that may conflict with our pipeline (verify before trusting)

From `threejs-3d-generator/SKILL.md` and `api-notes.md` (measured by the author, not by us):
- "Retarget v1.0 rigs with `--model-version default`" and "**v1.0 retargets must use `--out-format fbx`**: Tripo's GLB bake on this path writes twist-bone transforms in the wrong space and limbs collapse into the torso."
- "**Never pass `--animate-in-place`.** It corrupts the bake - mirrored and crossed limbs on v1.0, exploded skinning on v2.5." Convert to in-place at import by zeroing only horizontal `Root.position` values.
- "Do NOT strip or neutralize twist-bone tracks on v1.0 rigs."
- "Run `animate_prerigcheck` first ... `riggable=true` does not guarantee a usable rig. Validate the skeleton before retargeting - a 1-bone leg warps every clip." Retry rig (~25 credits) before regenerating the model.
- Their generation default is `v3.1-20260211`; ours is `P1-20260311` (they may differ in what is available to our account; not checked).

Our `tools/ai/tripo.mjs:193` does exactly the "forbidden" thing: `out_format: 'glb', bake_animation: true, ..., animate_in_place: true` on v1.0 biped. It evidently ships working characters
(and we have a whole Blender fix-up layer: `rigfix.py`, `retarget.py`, `cleanup.py`), so the skill may be describing a bug we already work around, or something that does not apply to our
presets/account. **Action for a future task (not now, costs credits):** one 10-credit A/B retarget of a single clip with and without `animate_in_place`, GLB vs FBX, on an existing rig task, then run
the skill's `validate-animation` on both. If the skill is right it explains some of the hand fixes in BLENDER-PIPELINE. We already do the rig-check (`tripo.mjs:183`) but have no equivalent of `validate-rig` (bone presence and chain depth) or `validate-animation` (scale tracks, limb-stretching translation, extreme rotations). Porting those two checks into `tools/blender/audit/` or `tools/ai/` is cheap (both are plain GLB parsing, no network).

### 3.6 Other small items

- `release-checks.md` "Traps": "Canvas is non-blank but the wrong app is running on that port" and "Dev server tested, production build shipped untested" - both have bitten us (stale dev servers; `run-all.mjs` already guards the first). Add the second as a step in the deploy checklist if not present.
- `evidence-manifest.md` run-ID idea: stops old screenshots being reused as new evidence. `run-all.mjs` already writes per-run dirs; adding a run id to each shot is a one-liner.
- Motion evidence guidance ("foot sliding relative to world displacement, root-motion double application, snapping transitions") is the right checklist for `necro-anim-smoke.cjs`/`anim-pass-smoke.cjs`.

## 4. `threejs-vfx` ("Elemental Sandbox")

| Item | Finding |
| --- | --- |
| License | `LICENSE` is MIT but names **"Copyright (c) 2026 mohamedachrefelouafi"**, while the only commit is by Majid Manzarpour and the README says "The original sandbox, and every technique this project is built on top of, is his work" (credits the same name). MIT text is valid whoever holds it, but the provenance/holder is unclear (probably a forked original). The README also says: *"The bundled HDR probe and the character FBX are third-party assets and retain their own licences; they are not covered by the MIT grant."* The four Mixamo FBX files and the HDR must **not** be copied. Keep the notice in any file we derive from. |
| Size and shape | 358 source files, ~64k lines of JavaScript (no TypeScript), 39 MB clone (9 MB src, 15 MB public). Docs it references (`docs/ROSTER.md`, `docs/VFX_API.md`) are **not in the repo**. |
| Structure | Not one file per effect: it is a **runtime**. `abilities/<school>/<Name>Ability.js` (500-1200 lines each) extends an `Ability` base (phase machine travel/impact/fade/done, pooled, no allocation after warm-up), registered in `abilities/registry.js`, with one `config/abilities/<id>.js` settings block per ability (every value a live lil-gui slider, ~16,000 of them). Each ability pulls on a shared library of 26 modules in `src/vfx/` (Tube, FilamentPaths, GroundField, Colony, HardSurface up to 3,282 lines, Dissolve, Shell, VolumeHull, Mirror...), ~60 bespoke materials in `src/materials/`, a GPU `ParticleSystem`, `GroundDecals`, `LightPool` (6 parked point lights), `FrameUniforms`, `Layers`, and a post stack (`GradeShader`, `DistortionShader` with half-res depth+distortion buffers). |
| Dependencies | `three ^0.185.1`, `lil-gui`, `vite ^8`. Our `three` is 0.166.1; our `vite` is 5.x. Shaders are hand-written GLSL via `onBeforeCompile`/`ShaderMaterial`; no WebGPU. |
| Perf claims (README) | "roughly a dozen draw calls for a whole cast"; default cast 32 idle / ~49-69 calls; ~480-1150 live particles; four concurrent casts peak at **~186 draw calls and five of six dynamic lights**; `Mirror` renders the world a second time and "is the most expensive thing here"; `VolumeHull` is fill-rate bound; pixel ratio capped at 1.75. Measured on desktop; **no mobile numbers anywhere**. For comparison our whole nave fight is 332 calls, so a single such spell would eat a large fraction of the mobile budget (150 calls). |
| Necromancer-relevant subset | **Void:** Soulchain (iron-link tether on a true catenary), Umbral Spears, Nightfall, Singularity, Unmake, Silence, Voidrift. **Blood:** Bonecage (`BoneRibMaterial`), Plaguebloom, Crimson Tide, Hemolance, Sanguine Pact. **Verdant:** Sporefall, Mycelium (rot/spore). **Hive:** Locust Tide, Web Line. **Stone:** Obsidian, Petrify. **Chrono:** Entropy (material ageing). No dedicated "bone/soul/spirit" school; those are spread across void and blood. |

**Fit verdict: do not integrate wholesale; mine techniques.** Reasons:
1. *Runtime mismatch.* Each ability assumes the sandbox's `Ability` base, `settings` tree, `FrameUniforms`, `Layers`, `LightPool`, `ParticleSystem`, `GroundDecals`. Our `Effects.ts` + `binbun/` + `necroFx.ts` + `SPELL_FX` are a different runtime, and CLAUDE.md requires every spell to take its colours from `SPELL_FX` ("don't make new content just violet"), whereas these abilities carry their own `accent`/palettes and ~hundreds of tunables each.
2. *Cost.* Even the cheap ones are 500-1,200 lines of JS plus 300-600-line materials plus shared modules in the thousands of lines; porting one effect realistically means porting a slice of the shared library too (estimate: 3-5 days for the first effect including shared pieces, 1-2 days for each additional one in the same school), JS to TS, three 0.185 to 0.166, plus re-budgeting for mobile.
3. *Perf.* Per-cast budgets (dozen draw calls, dynamic lights, a distortion pass, a Mirror pass) are fine for a one-hero sandbox, not for 30-80 enemies plus thralls plus several rites at once on a phone. The dynamic-light pool alone conflicts with our shadow/light budget (1 shadow caster on mobile).
4. *Provenance.* Copyright line mismatch and bundled third-party assets (above).
5. We already ported a large VFX library (Binbun, 67 effects) and just did a necro motif pass; the marginal gain of a second runtime is small versus finishing the perf phase.

**What is worth lifting (technique level, written fresh in our style, with attribution in the file header):**
- **Soulchain's catenary chain**: links placed by arc-length table on a `cosh` curve, instanced (`InstancedMesh`, one draw), JS mirror of the shader curve to avoid GPU read-back. Direct upgrade for Soul Siphon's tether and Bone Prison's bars (`Effects.ts`, `necroFx.ts`). Estimated 1-2 days.
- **"Whole bolt/snare is two draw calls": ribbon strip placed entirely in the vertex shader** (`effects/RibbonGeometry.js`). Good replacement for any line effect built from many sprites (Spear crack lines, Wailing Skull trail). 1 day.
- **Ground-footprint shader** (zone circle in metres, constant-thickness boundary): our AoE telegraphs (Black Litany, Miasma, Dirge) could use the exact "boundary stays 0.34 m thick whatever the radius" trick. Check against `ZONE-POLISH-AUDIT.md` telegraph findings.
- **Pooling contract** ("`spawn` must fully reset state, `destroy` must release, neither may allocate") and **`renderer.compileAsync` warm-on-select**: relevant to first-cast hitching; our `prewarmCreature.ts` is the analogue for FX.
- **Light pool parked at zero intensity** because "changing the light count forces three to recompile every material": a cheap rule to verify we never add/remove point lights at runtime.

Defer anything else until the perf phase lands; if VFX upgrades are wanted sooner, the lowest-risk path is *one* hero rite (Soul Siphon or Soulchain-like tether) as a pilot.

## 5. The other four repos (skim)

| Repo | License | What it is | Relevance |
| --- | --- | --- | --- |
| `threejs-procedural-dungeon` ("Dungeon Forge") | MIT | Seeded dungeon generator: scatter, separate, Delaunay, MST + loops, BFS room roles (entrance/combat/elite/treasure/shrine/boss), 5 themes, Vite app, 1.6 MB | Our world is a hand-authored connected map (`areas.ts`, `layout`). Could inform a future *procedural crypt/rift run* mode (graph layout + role assignment by BFS depth). Not for the current plan. **Skip, bookmark.** |
| `threejs-procedural-spider` | MIT | Analytic two-bone IK spider with improvised gait, no rig/clips, ~1,200 lines, 580 KB | Possible source for spider-type enemies or a Tripo-free crawler if Tripo rigs stay bad for multi-leg creatures (we needed `rigfix.py` for the cinderhound's missing forelegs). Technique reference for IK foot planting. **Skip, bookmark.** |
| `threejs-procedural-animals` | MIT | 24 SDF-meshed, rigged, furred animals at runtime, 5 quality tiers down to ~6k verts/one draw call (crowd), web workers, npm-style package, 6.2 MB | Interesting for ambient wildlife/crows/rats and crowd tier, but runtime SDF meshing and fur are far outside our asset pipeline and mobile budget. **Skip.** |
| `threejs-talking-avatar` | **Apache-2.0** (+ separate third-party terms incl. Google GNM-derived GLB) | WebGPU, WebAssembly, local STT/LLM/TTS talking head, 31 MB, several GB of browser model storage | Irrelevant to the game. **Skip.** |

## 6. Safety review

Everything below is from reading the files; nothing was executed.

| Item | Finding | Care needed |
| --- | --- | --- |
| Frontmatter | Only `name` and `description`; no hooks, no `allowed-tools`, no shell injection syntax | none |
| `install.sh` | Copies `skills/` into `~/.claude/skills` (and `~/.codex/skills`); skips existing names unless `--force`; `--prune-managed` can `rm -rf` directories listed in its own manifest | Do not run with `--force`/`--prune-managed`; it targets `$HOME` (global). We would copy by hand instead |
| `npx skills add ...` (README install path) | Runs a third-party CLI that fetches from GitHub into global dirs | Avoid; clone and review, then copy |
| `probe_asset_credentials.sh` | **Sources the user's `~/.zprofile`, `~/.zshrc`, `~/.bash_profile`, `~/.bashrc`** in a login shell, then prints only SET/MISSING | Reads shell profiles (may hold keys and run arbitrary profile code). Do not install/run; we keep keys in `.ai-keys.local` |
| `threejs_3d_asset.py` | Network: `api.tripo3d.ai` only (plus downloads from URLs Tripo returns); reads `TRIPO_API_KEY` or `--api-key`; writes only to `--out-dir`/`--checkpoint` paths; `unlink` only its own temp file; **submits paid tasks** | Spends credits; a second Tripo path beside our `tripo.mjs` would bypass our `--yes` dry-run gate and manifests. Its checkpoints store absolute paths |
| `threejs_audio_asset.py` | Network: `api.elevenlabs.io`; key from env/flag; writes to `--out` | New paid provider; not needed |
| `generate_image.py` | `google-genai` + pillow via `uv` inline deps (PEP 723): `uv run` would fetch packages from PyPI at run time | Network installs; duplicates `gemini.mjs` |
| `create_threejs_game.py` | Copies scaffold to a target dir; `--force` overwrites colliding files | Would overwrite files if pointed at our repo; never use here |
| `inspect-threejs-canvas.mjs` | Only talks to the `--url` (http/https validated); launches Chromium via Playwright (`channel: 'chromium'`); writes reports/PNGs to declared manifest paths; needs `@playwright/test` + `pngjs` in the project | Only if we port it; we already have Playwright via `DM_PLAYWRIGHT_MODULE` |
| `check_evidence.py` | Reads declared files; no network | none |
| Instruction conflicts | (1) "Never commit ... unless asked" is fine; but the director's "don't end a turn with an offer to continue / make routine calls yourself / complete authorized work" pushes autonomy beyond our approval boundaries (owner rule: propose-only + human approval for AI writes; CLAUDE.md: stage, don't commit). (2) "With keys set, premium hero surfaces get generated assets" would trigger Tripo/Gemini/ElevenLabs spend automatically; our grant is a ceiling (<= 1,500 Tripo credits) with spend reports. (3) Scaffold advice and `--force` overwrites assume an empty project. (4) Output paths (`assets/models/...`, `artifacts/`) differ from our `art-src/` (raw, gitignored), `public/models/`, `art-manifest/` rules; generated GLBs would land in the wrong places and skip manifests. (5) Assumes Three r184+, `three/addons` alias; ours is `three/examples/jsm` on 0.166. (6) Drives subagents/delegation by default. | Do not install the director or any generator; if any skill text is kept, strip these rules |
| Repo hygiene | No secrets found; keys only via env | none |
| `threejs-vfx` assets | Mixamo FBX characters + HDR are third-party | Never copy `public/`; do not vendor FBX/HDR into our repo |

## 7. Recommendation

### Top 5 things to take (in order)

1. **Adopt the render budget table as our written performance contract** (`technical-art.md`), use it as the acceptance bar for "Performance phase 1" and add a tier check to `tools/qa/scene-categories.cjs`. Our nave fight (332 calls / 804k tris / 488 MB textures) is the concrete gap.
2. **Add pixel-metrics QA** (port `computePixelMetrics`, ~60 lines + `pngjs`) with **per-zone baselines, not their thresholds**, to `zone-tour.cjs` / `mobile-shots.cjs` / `spell-feel-smoke.cjs`; catches flat/over-dark/clutter regressions that behavioural smokes miss.
3. **Add a bot playtest smoke with softlock-window detection and a two-skill-level difficulty check** (`playtest-bot.md`), driving real key events (not `goto`) through zones; complements the analytic `npm run balance`.
4. **Cherry-pick shader recipes into small files in the existing `onBeforeCompile` style**: dissolve (corpses/thrall despawn), wind sway (Fen/Nave instanced props), scrolling emissive (rune/Bell Sanctum), fake glass and fake contact shadow (alchemy props, flyers/loot). Each is under 25 lines and documents its cost.
5. **Verify the Tripo animation facts and port the two validators** (`validate-rig`, `validate-animation`) into our tooling; run the single 10-credit A/B on `animate_in_place` and GLB-vs-FBX for v1.0 retargets. Potentially removes manual Blender fix-ups; at minimum gives automatic warp detection before assets ship.

Honourable mentions: the scorecard rubric for zone audits; the `asset-recovery.md` "never re-submit after an uncertain POST" table; Soulchain's catenary-link technique for Soul Siphon/Bone Prison.

### `threejs-vfx`

Do not integrate. Treat as a technique library; if a VFX pilot is approved, make it a single rite (tether) written in TS against `Effects.ts`/`SPELL_FX`, mobile-budgeted, with attribution.

### Install plan

**Do not install any of the nine skills globally.** The director/generators conflict with our rules, one script reads shell profiles, and installing into `~/.claude/skills` would make them fire in unrelated VPS projects (CrossWorlds, Workbench, etc.).

If the owner still wants them available to Claude in this project only, the safest route is **project-local, graphics + QA reference only**, committed in the game repo (small: ~40 KB of markdown, 3 JPG anchors ~160 KB, and the inspector only if ported). Suggested minimal set, adapted as reference (not as auto-trigger) skills:

| Install as | From | Adaptation |
| --- | --- | --- |
| `.claude/skills/threejs-graphics-reference/` | `threejs-aaa-graphics-builder` (`SKILL.md`, `references/technical-art.md`, `shader-cookbook.md`, `visual-scorecard.md`; skip `authoring-recipes.md` or keep for procedural props) | Rewrite `description` to trigger only on "render budget, shader, material, post-processing, performance review" for Death Muffin; delete "With keys set, generate hero assets" and the credential-probe lines; remove the "premium needs average >= 2.3" mandate or keep it as an optional rubric; point at our files (`GameRuntime.ts`, `friendRim.ts`) |
| `.claude/skills/threejs-qa-reference/` | `threejs-qa-release` (`references/playtest-bot.md`, `visual-test-harness.md`, `release-checks.md`) | Drop the scaffold references (`tests/bot-playtest.template.ts`), replace "inspect:canvas" with our `tools/qa/run-all.mjs`/`__cwDebug`; note that thresholds are not calibrated for dark art |
| `docs/reference/` (plain docs, no skill) | `threejs-3d-generator/references/api-notes.md`, `threejs-integration.md` | As reading material for the Tripo A/B; no scripts |

Exact commands (**not run**; paths assume the repo root `/home/ubuntu/vps-handoffs/DeathMuffin/<tree>`; run from a scratch clone, review the diff, then stage):

```bash
# 1. fetch read-only (already done during this evaluation in a scratch dir)
git clone --depth 1 https://github.com/majidmanzarpour/threejs-game-skills /tmp/mm-skills
S=/tmp/mm-skills/skills

# 2. project-local, graphics reference skill (copy only what is reviewed)
mkdir -p .claude/skills/threejs-graphics-reference/references .claude/skills/threejs-graphics-reference/assets
cp $S/threejs-aaa-graphics-builder/SKILL.md .claude/skills/threejs-graphics-reference/SKILL.md
cp $S/threejs-aaa-graphics-builder/references/{technical-art,shader-cookbook,visual-scorecard}.md \
   .claude/skills/threejs-graphics-reference/references/
cp -r $S/threejs-aaa-graphics-builder/assets/scorecard-anchors .claude/skills/threejs-graphics-reference/assets/
cp /tmp/mm-skills/LICENSE .claude/skills/threejs-graphics-reference/LICENSE-threejs-game-skills.txt
# then edit SKILL.md: rename, rewrite description, strip generation/credential/premium-mandate text

# 3. project-local QA reference skill
mkdir -p .claude/skills/threejs-qa-reference/references
cp $S/threejs-qa-release/SKILL.md .claude/skills/threejs-qa-reference/SKILL.md
cp $S/threejs-qa-release/references/{playtest-bot,visual-test-harness,release-checks}.md \
   .claude/skills/threejs-qa-reference/references/
# then edit SKILL.md as above; do NOT copy scripts/ or run install.sh

# 4. stage explicit paths only (never git add -A; the game tree is shared and the owner commits via GitHub Desktop)
git add .claude/skills/threejs-graphics-reference .claude/skills/threejs-qa-reference
```

Notes: `.claude/skills/` is not in `.gitignore`, so it would be tracked; `.claude/launch.json` is already tracked, so a project `.claude` folder is an accepted pattern here.
Do **not** use `./install.sh`, `npx skills add`, or anything under `~/.claude`. The Tripo/Gemini/ElevenLabs skills, the director, UI designer and debug-profiler should not be installed.

### Suggested follow-up tasks (none started)

| # | Task | Size | Cost |
| --- | --- | --- | --- |
| 1 | Write `docs/PERF-BUDGET.md` (table above vs measured, per quality tier) and a budget check in `scene-categories.cjs` | S | 0 |
| 2 | `tools/qa/lib/pixel-metrics.cjs` + per-zone baselines in `zone-tour.cjs` | S-M | 0 |
| 3 | `tools/qa/bot-playtest.cjs` (softlock windows, two reaction delays) | M | 0 |
| 4 | Dissolve + wind-sway + scrolling-emissive patches (`src/graphics/`), behind Low-quality skips | M | 0 |
| 5 | Tripo A/B retarget (one clip, GLB vs FBX, in-place on/off) + port `validate-rig`/`validate-animation` | S | ~20-40 credits |
| 6 | Optional pilot: Soulchain-style instanced catenary tether for Soul Siphon | M | 0 |
