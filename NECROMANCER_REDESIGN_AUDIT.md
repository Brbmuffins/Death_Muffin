# Crossworlds Web — Necromancer Redesign Audit

Audit date: 2026-09-26  
Repository reviewed: `Brbmuffins/Cross-Worlds-Web`, private, `master`, commit `68023fe` (2026-07-03)  
Live build reviewed: `https://playcrossworlds.com/play/`

## Executive assessment

Crossworlds is not an empty prototype. It already has a coherent browser-game spine: account creation and login, character selection, a hub, inventory and professions, crafting, click-to-move combat, four active abilities, loot, XP and levels, four-player Socket.io presence, an arena, and a three-phase boss. It also has a credible AI-assisted asset pipeline for 2D images and rigged 3D characters.

What it does not yet have is a strong game identity. The live build reads as polished “cosmic fantasy portal” rather than necromancy. In-game spaces are circles made from basic Three.js primitives, the HUD resembles a modern glass dashboard, enemies are spheres, loot is octahedra, and the boss is an emissive icosahedron. The systems demonstrate functionality but do not yet reinforce one another as a dark-fantasy experience.

The best redesign is therefore not a skin swap. It should turn the existing loop into a persistent corpse-and-loot economy:

> Enter one connected, desecrated world; farm increasingly dense enemy waves; turn corpses into minions or spell fuel; collect loot; and reinvest it into damage, wave speed, and new areas.

This direction reuses the strongest existing work—click-to-move, the four-slot bar, loot/crafting, co-op rooms, boss phases, GLB characters, and sprite VFX—while giving every system a necromantic purpose.

## Current game audit

### Current player loop

The implemented flow is:

1. Register or log in against the existing Node/Express auth service.
2. Create or load one of four visible classes: Guardian, Shadowblade, Cleric, or Arcanist. Engineer remains a legacy server index with no model.
3. Enter the hub, inspect stats, inventory, professions, party presence, and chat.
4. Craft copper recipes or equip items.
5. Walk through an arena portal.
6. Kill four endlessly respawning slime simulations, collect client-rolled copper loot, and bank 10 XP per kill.
7. Return to the hub to save progression.
8. Enter a separate boss portal and fight the 800-HP Void Warden through three phases for 250 XP and guaranteed copper loot.

The moment-to-moment controls are already close to the requested reference: fixed overhead camera, click-to-move, click an enemy to chase and auto-attack, and abilities on 1–4. WASD is retained as a fallback.

The weak point is purpose. The arena is an endless test room without meaningful wave escalation, build growth, or geographic progression; the boss portal is immediately available; and the economy contains only a few copper items. Killing, looting, upgrading, and bossing should become one continuous farming loop rather than separate demonstrations.

### Combat and progression

Strengths:

- Four-slot ability bar with cooldown sweeps and generated icons.
- Target chasing for melee and ranged basic attacks.
- AoE abilities, floating damage, additive hit sprites, HP bars, death/respawn, and three boss phases.
- Inventory-backed stats, equipment, crafting, professions, loot pickup, XP, and level persistence.
- The arena functions offline and adds realtime co-op when the service is available.

Limitations:

- All four classes share the same ability template: basic, heavy, nova, ultimate. Only names, range, color, and multipliers change.
- Combat has no statuses, resource tension, corpses, summons, crowd control, enemy tells beyond the boss slam, or meaningful target priority.
- The arena has four copies of one sphere enemy. The generated slime model exists but is not wired.
- Loot is rolled client-side and saved as a full inventory array. It is adequate for friendly PvE but is exploitable.
- Arena and boss stat formulas disagree. Arena HP is `50 + VIT × 5`; boss HP is `100 + VIT × 2`. Attack formulas also differ.
- Progress saves fire-and-forget during scene transitions, with no retry or visible recovery state.
- The boss reimplements large portions of arena combat and VFX instead of sharing systems.

### UI and visual theme

The live login is clean and functional, but its identity is celestial rather than necromantic: a purple crystal emblem, floating purple/teal/gold shards, cyan links, gold labels, white form fields, and a translucent rounded panel. The same design language continues in the game through cyan borders, blurred glass panels, pills, rounded cards, emoji action buttons, and Segoe UI.

That creates three problems:

- It feels like a fantasy-themed web dashboard rather than an artifact from the game world.
- The palette is dominated by electric cyan, clean violet, and clean black. The redesign can keep purple, but it needs depth: layered blacks, ink plum, ultraviolet spelllight, bone, soot, and cold silver rather than bright red or clean neon gradients.
- UI surfaces and the 3D world do not share materials. The UI is glass; the world is untextured geometry.

Useful elements worth keeping are the strong silhouette of the logo, clear form hierarchy, readable ability bar, concise inventory grid, explicit error messages, and the restrained amount of on-screen information.

Accessibility is mixed. Login fields are labeled and image fallbacks exist, but combat feedback relies heavily on color, the canvas has no nonvisual game-state equivalent, small hint text carries important controls, and the class/rarity palette is not reinforced consistently with shapes or labels.

### Architecture

The project is a compact Vite + TypeScript + Three.js application. `SceneManager` swaps class-based scenes. Each scene directly creates its Three.js scene, renderer, camera, DOM, input listeners, networking client, simulation objects, and persistence calls.

This was efficient for a vertical slice, but it is now the main scaling constraint:

- `HubScene`, `ArenaScene`, and `BossScene` are large orchestration classes with rendering, UI, input, simulation, networking, and API concerns intertwined.
- Every scene creates and disposes its own WebGL renderer. This causes shader/material churn and makes transitions harder to polish.
- `fitToWindow()` installs a resize listener but returns no cleanup function, so scene changes leak listeners.
- Arena and boss duplicate player stats, ability casting, cooldown UI, damage text, hit-sprite VFX, remote-player rendering, and movement logic.
- Core data frequently uses `any`, especially character and realtime event payloads.
- Asset loading has no central cache or preload manifest.
- VFX create nested `requestAnimationFrame` loops and timers per effect instead of using one managed effect system.
- There are no automated tests in the package scripts, despite project notes describing manual browser QA.

The REST boundary is sensible: a small client wraps the existing auth, inventory, profession, crafting, and progression endpoints. Auth tokens are kept in `sessionStorage`, which is preferable to persistent local storage but remains exposed to any successful XSS.

The realtime layer needs attention before broader co-op work:

- Clients join literal room names `hub`, `arena`, and `boss`. These are global rooms capped at four players, not independent parties or run instances.
- The service treats `arena:event` payloads as opaque and does not enforce that only the elected host may send authoritative enemy or boss state.
- Position, combat, loot, and progression remain client-authoritative.
- The server validates JWT identity but trusts the supplied character ID, class index, coordinates, and event shapes.
- Host migration elects the oldest socket but does not transfer a canonical simulation snapshot.

This is acceptable for a private cooperative prototype, but the global-room behavior will break as soon as more than four people use the same scene.

### Assets and generation workflows

The repository contains more production work than the root README advertises.

Current 2D assets:

- 16 Gemini-generated ability icons: four per current class.
- 3 item icons for copper shard, copper bar, and copper ring.
- 10 status icons, including void rot, cursed, withered, sanctified, burning, and hemorrhage. These are mostly not wired into gameplay.
- 5 additive hit sprites for physical, void, holy, frost, and fire.
- Four hero portraits, a transparent Crossworlds logo, and nine original/reference images in `Inspiration ART`.

Current 3D assets:

- Guardian, Bo-Gar, and Arcanist rigs with idle, walk, run, hurt, and attack clips.
- Brandolf with idle, walk, run, and hurt; his attack retarget remains pending.
- A static slime GLB that is not yet used in the arena.
- Shipped model payload is documented at about 13 MB, reduced from roughly 1.7 GB of raw Tripo output.

The Tripo workflow is unusually well documented. Raw generations and task JSON are kept under gitignored `art-src/tripo/<slug>`. A repeatable `tools/build-models.mjs` pipeline converts FBX animation families to GLB, strips animation geometry, simplifies rigs to roughly 75k triangles, compresses textures to 1K WebP, quantizes, and writes stable public paths. The code correctly handles a Tripo rest-pose mismatch by deriving the runtime rig from the idle FBX rather than mixing GLB and FBX skeleton spaces.

Gaps in reproducibility:

- The repository records that 34 Gemini assets were generated, but it does not contain a prompt/seed/model manifest or generation script for them.
- Raw Tripo assets and task metadata are gitignored, so another machine cannot reproduce models from this repository alone.
- The model builder hardcodes the Windows `FBX2glTF.exe` location.
- There is no validation step in CI for triangle count, texture dimensions, animation names, bounding boxes, or missing manifest entries.
- No audio pipeline or shipped audio assets were found. Earlier plans mention ElevenLabs, but no working audio-generation workflow is present.

## Recommended creative direction

### Core fantasy: The Ossuary Covenant

The player is not merely a wizard with purple spells. They are a sanctioned grave-worker reclaiming a ruined diocese where the dead are trapped between burial and damnation. The hub is the collapsed chapterhouse beneath a cathedral. Expeditions descend through ossuaries, flooded crypts, plague cloisters, and bell towers. Every corpse is both evidence of violence and a tactical resource.

This premise supports co-op without making every player visually identical. The world is a single connected hunting ground—graveyard, ossuary, ruined nave, and deeper sanctums—where players can keep farming instead of repeatedly extracting and restarting. Keep the server's class indices during the transition, but present them as four necromantic disciplines:

- Index 1 — Ossuary: bone armor, body blocking, marrow weapons, defensive minions.
- Index 2 — Gravecaller: fast corpse consumption, skeletal thralls, sacrifice bursts.
- Index 3 — Mourner: spirit binding, healing through funerary rites, protective wards.
- Index 4 — Rotweaver: miasma, decay stacks, corpse detonation, ranged control.

The server can continue storing the legacy indices while the client uses a content manifest for display names, kits, VFX, and model mapping. A later migration can rename server classes without blocking the redesign.

### Visual grammar

Avoid “black with red neon.” Make black and purple the dominant identity, then keep it readable through material contrast:

- Blacks: soot, obsidian, ink, and plum-black, separated by roughness and value rather than one flat void.
- Purple magic: bruised violet for ambient corruption, ultraviolet for active spells, and pale lilac for the hottest magical core.
- Bone: old ivory and ash grey, used as a restrained readability accent.
- Grave soil: near-black brown with cold violet reflections.
- Stone: charcoal limestone, silver salt bloom, soot, and dead moss.
- Metal: blackened iron and oxidized silver; avoid polished gold and bright red ornament.
- Blood: dried brown-black used sparingly, never as the primary glow color.

Light should reveal ritual meaning. A room can remain dark while bone piles, chalk circles, hanging censers, corpse candles, and violet mist define navigation. Interactables should use contained lilac cores, orbiting runes, and pale bone highlights—not red outlines or generic purple bloom over everything.

Suggested base palette:

- Void black `#07060a`
- Obsidian `#0d0b11`
- Plum shadow `#17101d`
- Ritual stone `#24202b`
- Old bone `#d8cfbd`
- Corpse silver `#96a0b5`
- Veil violet `#7c3aed`
- Spell purple `#9b5cff`
- Arcane lilac `#c6a4ff`
- Dried blood `#4a2d35`

### World and UI

Hub: replace the empty circular platform with the ruined chapterhouse. The center is a cracked burial slab used as the party table. Inventory is a reliquary chest. Crafting is an ossuary workbench. Professions become rites learned from wall niches. Portals become physical thresholds: a sealed crypt stair and a bell-tower transept.

World: replace the flat red circle with one continuous farming space assembled from reusable rooms: a graveyard court, bone-packed ossuary, collapsed nave, and sealed inner sanctum. Doors and short corridors preserve the feeling of one world while allowing loading and pacing boundaries. Each area has its own enemy table, density ceiling, loot bias, and optional boss threshold. Cleared mobs repopulate through visible grave breaches and ritual gates instead of popping into existence.

Boss: replace the Void Warden with the Bell-Sworn Prelate, a cathedral corpse fused to a cracked processional bell. Phase changes extinguish or corrupt different candle groups, alter the floor sigil, and add spirit processions. This preserves the existing three-phase simulation while giving attacks readable physical causes.

UI: make panels feel like grave rubbings and reliquaries, not glass cards. Use thin engraved borders, chipped corners, parchment-dark surfaces, bone dividers, and subtle soot texture. Keep spacing and legibility. Replace rounded pills with compact tab-like plaques. Use a readable old-style serif for headings and a neutral humanist sans for numbers/body text. Do not use novelty blackletter for paragraphs.

The ability bar becomes four inset reliquary slots connected by a faint chalk arc. Cooldowns drain as shadow passing over carved icons. Health uses dark crimson-brown wax, while the new Grave Essence resource uses sickly spelllight. Minion count appears as three small bone markers rather than another numeric pill.

## Redesigned gameplay loop

### Persistent farming loop

1. Enter the shared world at the ruined chapterhouse and walk into any unlocked hunting area.
2. Kill continuously spawning enemies to create corpses, XP, currency, and equipment drops.
3. Decide whether each corpse becomes Grave Essence, a temporary thrall, a detonation, or fuel for an area ritual.
4. Equip useful drops immediately; send overflow to the reliquary stash without ending the session.
5. Spend earned currency on two clear power axes: damage and wave speed. Damage increases clear power; wave speed reduces downtime and raises spawn density, risk, and reward multipliers.
6. Reach area kill thresholds to open adjacent rooms, trigger elite packs, or awaken a local boss.
7. Defeat bosses for targeted loot, then continue farming the same world or move freely between unlocked areas.
8. Preserve progression on disconnect and return the player to the chapterhouse; there is no extraction or forced run reset.

Wave speed must remain a player-controlled risk lever, not a simple waiting-time upgrade. Each tier should shorten the next-wave delay, allow more simultaneous enemies, and slightly improve rarity or currency yield. Cap it per area so density never exceeds the browser performance budget.

### First playable necromancer kit

- Primary click: Bone Needle. Fast low-damage projectile; generates a small amount of Grave Essence on hit.
- 1 — Marrow Spear. Line attack that pierces and applies Fracture.
- 2 — Exhume. Consumes a nearby corpse to raise a temporary skeletal thrall; three-thrall cap.
- 3 — Miasma Circle. Ground-targeted zone that slows and applies Withered.
- 4 — Black Litany. Converts all active corpses and thralls into a ritual burst; power scales with what is sacrificed.

This kit immediately differentiates attacks by targeting mode and resource use. It also gives the existing status icons a job. Later disciplines can remix the same corpse API instead of duplicating combat code.

### Minimum enemy roster

- Grave robber: mobile melee baseline; leaves a normal corpse.
- Bellbound penitent: ranged warning cone; death leaves a resonant corpse that empowers rituals.
- Bone hound: fast flanker; corpse can be raised as a fast minion.
- Carrion sac: slow hazard enemy; corpse decays into a toxic zone if not consumed.
- Crypt deacon: support enemy that reanimates nearby corpses before the player can use them.

These five behaviors create target priority and make corpse ownership matter without requiring a huge content library.

## Implementation architecture

### Runtime extraction

Create one persistent `GameRuntime` that owns the renderer, camera service, resize cleanup, clock, input router, asset cache, and effect pool. Scenes should provide `enter`, `update`, and `exit` methods but should not create their own renderers.

Suggested structure:

```text
src/
  app/
    GameRuntime.ts
    SceneRouter.ts
    AppState.ts
  content/
    disciplines.ts
    abilities.ts
    encounters.ts
    items.ts
  gameplay/
    combat/CombatSystem.ts
    combat/StatusSystem.ts
    corpse/CorpseSystem.ts
    minions/MinionSystem.ts
    encounters/EncounterDirector.ts
    progression/CharacterStats.ts
  graphics/
    AssetCache.ts
    EnvironmentKit.ts
    LightingRig.ts
    EffectPool.ts
  net/
    contracts.ts
    realtime.ts
  scenes/
    ChapterhouseScene.ts
    CryptScene.ts
    PrelateScene.ts
  theme/
    tokens.css
    components.css
  ui/
    HUD.ts
    ReliquaryPanel.ts
    RitualPanel.ts
```

### Data-driven content

Move ability names, icons, targeting modes, costs, cooldowns, status effects, and VFX keys into typed definitions. Scenes should invoke an `AbilitySystem`; they should not contain spell-specific branching.

Introduce shared types for `Character`, `Combatant`, `AbilityDefinition`, `StatusDefinition`, `Corpse`, `Minion`, `Encounter`, and realtime event unions. Remove `any` from scene constructors and socket messages.

Centralize derived stats in one `CharacterStats` module used by arena and boss. Add a schema version to saved progression and inventory payloads before expanding item types.

### Realtime model

Replace global scene rooms with instance keys such as `party:<partyId>:world:<worldInstanceId>`. The server should create or join a persistent world through explicit acknowledgements and validate membership. Solo and invited-party worlds can use the same contract; neither requires an extraction lifecycle.

For the near term, keep host simulation but enforce it server-side:

- Only the elected host can publish enemy/boss snapshots.
- Non-host players may send bounded hit intents, never arbitrary state objects.
- Validate event type, numeric bounds, rate, room membership, and payload size.
- Persist the latest canonical snapshot on the server for host transfer.
- Separate reliable events (spawn, death, loot, phase transition) from volatile transforms.

Before any competitive economy, make loot and progression server-authoritative. For the redesign's first cooperative milestone, server-validated encounter completion and reward grants are the minimum safe boundary.

### Rendering and performance

- Reuse one WebGL renderer across scenes.
- Convert the 90 login crystals to an `InstancedMesh`, or replace them with low-cost fog, dust, and candle motes.
- Add a central GLTF/texture cache and a preload manifest per scene.
- Use pooled sprites and one update loop for VFX instead of a new RAF chain per effect.
- Dispose resize/input/network subscriptions through a common scene scope.
- Add modular environment batching and instancing for candles, bones, pillars, and grave markers.
- Preserve the existing 2× pixel-ratio cap and Three.js manual chunk.

## Asset-pipeline redesign

Keep the Tripo conversion pipeline, but add a manifest beside every generated asset:

```json
{
  "id": "bone-hound-v1",
  "generator": "tripo",
  "model": "record exact model/version",
  "taskIds": [],
  "promptFile": "prompts/bone-hound.md",
  "sourceHash": "sha256:...",
  "license": "record account/output terms",
  "clips": ["idle", "walk", "run", "hurt", "attack", "death"],
  "runtime": { "height": 1.1, "triangleBudget": 35000, "textureMax": 1024 }
}
```

Do the same for Gemini icons and VFX: prompt, negative constraints, model/version, aspect ratio, source image references, output hash, crop treatment, and transparency treatment. Generation should produce source assets outside `public`; a deterministic processing step should create runtime PNG/WebP atlases.

Prioritized asset list:

1. Modular cathedral kit: floor, broken wall, arch, column, tomb, stair, iron fence, bone pile, ritual decal.
2. Necromancer hero with idle, locomotion, cast, summon, hurt, and death.
3. Skeleton thrall and bone hound, both using the same animation naming contract.
4. Five enemy silhouettes from the roster above.
5. Bell-Sworn Prelate boss.
6. Spell atlas: bone impact, corpse mist, spirit wisp, chalk sigil, miasma, summon burst.
7. UI atlas: frame corners, dividers, plaques, cursor states, minion markers.
8. Audio: low cathedral wind, soil movement, bone articulation, candle hiss, distant bell, four spell families, and readable enemy tells.

Use procedural primitives only as greybox geometry. Avoid asking an image generator for full UI screenshots to slice apart; generate controlled ornaments and textures that can be assembled responsively in CSS.

## Concrete roadmap

### Phase 0 — Stabilize the foundation (2–4 developer days)

- Create a redesign branch and capture baseline screenshots/performance numbers.
- Add `typecheck`, unit-test, and browser-smoke scripts to `package.json`.
- Make `fitToWindow()` return cleanup and remove all leaked listeners.
- Introduce the persistent renderer/runtime and shared character stats.
- Add typed realtime event unions.
- Change room naming to party/world instances and enforce host-only snapshots.

Exit criteria: existing login, hub, arena, boss, inventory, crafting, and solo fallback still work; repeated scene transitions do not increase listeners or WebGL contexts; two independent four-player parties can occupy separate world instances.

### Phase 1 — Necromancer vertical slice (1–2 weeks)

- Add the new palette/tokens and redesign login, character selection, HUD, inventory, and ability bar.
- Build a greybox chapterhouse, graveyard room, and connecting crypt threshold.
- Implement Grave Essence, corpse spawning/expiry, Exhume, thrall cap, Miasma, Fracture, and Withered.
- Reframe the current four server class indices as necromantic disciplines in a client content manifest.
- Wire the existing slime model as a temporary enemy so no combatant remains a sphere.

Exit criteria: a new account can enter the graveyard, farm continuous waves, create and consume corpses, raise three thralls, receive a server-validated drop, buy one damage tier and one wave-speed tier, and cross a room threshold without console errors.

### Phase 2 — Persistent farming loop (1–2 weeks)

- Add `WaveDirector` with per-area spawn tables, density caps, elite thresholds, and visible spawn gates.
- Add the first five-enemy roster with distinct corpse properties.
- Add damage and wave-speed upgrade tracks, loot rarity scaling, and the first grave-relic recipes.
- Replace immediate boss access with area kill thresholds or a crafted summoning key.
- Add death/recovery, reconnect persistence, and safe return-to-chapterhouse behavior.

Exit criteria: a 15+ minute session supports uninterrupted farming across at least two connected areas, upgrades noticeably change clear speed and enemy pressure, progression persists cleanly, and reconnecting cannot duplicate rewards.

### Phase 3 — Environment and character art (2–3 weeks, parallelizable)

- Generate and optimize the cathedral kit, hero, thralls, enemies, and boss.
- Build material presets for bone, limestone, damp soil, wax, iron, brass, cloth, and ectoplasm.
- Add decals, fog volumes, instanced candles/bones, light probes, and restrained postprocessing.
- Add audio with explicit telegraphs and ambient layers.
- Add generation manifests and asset validation.

Exit criteria: no primitive placeholder is visible in the vertical slice; scene-specific asset budgets and 60-FPS desktop target are met on the chosen reference hardware.

### Phase 4 — Co-op authority and progression (1–2 weeks)

- Move encounter completion, boss death, and reward grants to the server.
- Add canonical host-transfer snapshots and event rate limits.
- Expand item/status schemas and migrate copper-only content into relic tiers.
- Add party formation/invite codes rather than automatic global-room joins.

Exit criteria: host departure during an encounter recovers without reset; malformed or non-host state messages are rejected; duplicate rewards are not possible through reconnecting.

### Phase 5 — Boss, polish, and release QA (1–2 weeks)

- Implement the Bell-Sworn Prelate using the existing three-phase framework.
- Add controller/keyboard parity, color-independent tells, motion-reduction options, graphics presets, and audio sliders.
- Add visual-regression shots for login, chapterhouse, crypt, inventory, and boss.
- Add performance budgets, asset-size checks, console-error checks, and deployment smoke tests.

Exit criteria: production build, private-session auth, solo play, two-party isolation, four-player boss, save/reload, reconnect, low graphics, and reduced-motion paths all pass.

## First change set to implement

The safest first pull request should be architectural and thematic, not a mass asset replacement:

1. Add `src/theme/tokens.css` and migrate existing CSS colors, radii, shadows, and type to semantic variables.
2. Make renderer/resize/input lifetime explicit and leak-free.
3. Add shared `CharacterStats` and `AbilityDefinition` types; make Arena and Boss consume them.
4. Add `partyId` and `worldInstanceId` to realtime joins; remove literal global `arena` and `boss` rooms.
5. Add a typed `CombatEvent` union and server validation.
6. Add corpse/minion interfaces behind feature flags, with no gameplay behavior yet.
7. Add a browser smoke test that reaches login and verifies a nonblank canvas and no console errors.

This gives the redesign a stable seam. The second change set can then implement the necromancer vertical slice without continuing to grow the current monolithic scene files.

## Repository preparation status

No source changes were applied to the private repository. The signed-in browser could read it, but command-line checkout was not authorized by GitHub and the browser's archive endpoint was blocked, so a safe editable working copy was not available in this workspace. This audit and the companion token file are ready to copy into the repository once it is connected or cloned locally.
