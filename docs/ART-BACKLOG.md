# Art backlog — generated art and where it stands

The single place to track generated art: what is **live in the game**, and what is **ready and waiting for
code**. It was generated 2026-09-27 on the workstation through the Gemini → Tripo pipeline
(`ASSET_PIPELINE.md`). The owner asked for art ahead of each roadmap, so any agent building a feature should
check here first and **wire the existing art instead of making stand-ins**.

- **Regenerate the "no code yet" list:** `node tools/art-backlog.mjs`. It reports every file under
  `public/art` and `public/models` that no loaded module references. Item icons count as live once their id
  exists in `content/items.ts`, because InventoryPanel and LootView load `art/items/<id>.png` by name.
- **Where things came from:** Gemini jobs in `art-manifest/gemini-jobs/*.json` (outputs recorded in
  `art-manifest/images.json`), Tripo specs in `art-manifest/tripo-specs/*.json`, and Tripo records (task ids,
  credits) in `art-manifest/tripo/*.json`. Raw outputs and concept sheets live in the workstation's gitignored
  `art-src/`, so rebuilding a GLB needs that machine.
- When you wire an asset, move its row to "Live" (or delete it) in the same change.

## 1. Professions, crafting and grinding

Roadmap: [`PROFESSIONS-ROADMAP.md`](PROFESSIONS-ROADMAP.md). Wiring notes: [`agent-briefs/professions-g3-art.md`](agent-briefs/professions-g3-art.md).

### Live in the game

| Art | Files | Used by |
|---|---|---|
| Trees, stump, seams, geode, rubble, graves (incl. crypt collapse + barrow tomb) | `public/models/props/prop_node_{coffin_oak,hangman_elm,bleeding_willow,churchyard_yew,blackthorn,ghostwood,bone_elder,stump,ore_seam,ore_geode,ore_spent,burial_mound,dug_grave,crypt_collapse,barrow_tomb}.glb` | `src/graphics/NodeViews.ts` `MODEL` |
| Bone Kiln | `public/models/props/prop_node_bone_kiln.glb` | `layout.ts` `PROPS` |
| Gathered-goods icons (21) | `public/art/items/{log_*,fish_*,bones_*,gem_*,seed_mourning_moss,reliquary_fragment,covenant_seal}.png` | Item ids from the professions build |
| Existing items that had no icon (17) | `public/art/items/{ingot_tin,ore_bronze,ingot_bronze,ingot_silver,ore_steel,ingot_steel,ore_hell,ingot_hell,ore_moon,ingot_moon,fish_river,fish_fillet,plank_oak,flask_speed,flask_damage,flask_void_resist,bow_oak}.png` | Inventory and loot (by name) |
| Hero swing clip | `attack` clip in `public/models/{necromancer,hero_ossuary,hero_gravecaller,hero_mourner,hero_rotweaver}/character.glb` | Present on every hero. Nothing plays it yet; it's the chop and pickaxe swing for the gathering loop |

### Ready, waiting for code

| Art | Files | Intended use | Waiting on |
|---|---|---|---|
| Stations (6) | `public/models/props/prop_node_{sawpit,alchemy_table,sexton_vault,cook_cauldron,grave_anvil,compost_heap}.glb` | Carpentry, Alchemy, bank, Cooking, Smithing, compost | G6/G7 stations (add to `PROPS` + panel) |
| Garden (4) | `prop_node_{garden_plot,garden_sprouts,herb_patch,sapling}.glb` | Empty → sprouting → grown plot; tree-patch sapling | G5 Grave Gardening |
| Fishing marker | `prop_node_black_water_pool.glb` | A still-pool prop for the Acre pond edge (pools themselves are ripples) | Optional (G2 decoration) |
| Per-ore seam bakes (9) | `prop_node_ore_seam_{copper,tin,iron,bronze,silver,gold,steel}.glb`, `prop_node_ore_geode_{moon,hell}.glb` | Alternative to the crystal overlay: one baked seam per ore (`tools/tint-variants.mjs`) | Optional |
| Hand tools (4) | `public/models/props/tool_{pickaxe,hatchet,spade,fishing_rod}.glb` | Attached to the hero's hand while gathering (`Creature.attach`), with the `attack` swing | G1 follow-up |
| Herbs, seeds, saplings (14) | `public/art/items/herb_{mourning_moss,nightshade,corpse_lily,wolfsbane,bloodroot,moonpetal}.png`, `seed_{nightshade,corpse_lily,wolfsbane,bloodroot,moonpetal}.png`, `sapling_{coffin_oak,churchyard_yew,bone_elder}.png` | Grave Gardening items | G5 item ids |
| Processing (12) | `public/art/items/plank_{elm,willow,yew,blackthorn,ghostwood,bone_elder}.png`, `meal_{crypt_eel,bell_carp,drowned_pike,lanternfish,coelacanth}.png`, `bone_meal.png` | Carpentry planks, Cooking meals, compost | G6 recipes and ids |
| Tool tiers (24) | `public/art/items/tool_{pickaxe,hatchet,spade,rod}_{copper,iron,silver,steel,hell,moon}.png` | Smithing-made tools that make gathering faster (the grinding ladder) | G6 tool items |
| Finds and contracts (3) | `public/art/items/{crows_nest,drowned_locket,sexton_contract}.png` | Rare finds and daily Sexton's contracts | Loot tables; G7 contracts |
| Skill icons (9) | `public/art/skills/{woodcutting,mining,fishing,gravedigging,gardening,smithing,carpentry,cooking,alchemy}.png` | Skills panel, level-up banners, leaderboard | G4 polish; G7 leaderboards |

## 2. Combat, classes and bosses (FUTURE_CONTENT.md)

| Art | Files | Intended use | Waiting on |
|---|---|---|---|
| Thrall gear (2) | `public/models/props/gear_{thrall_bow,bone_staff}.glb` | Replace the code-built bow and staff on archer and bone-mage thralls | `EntityViews` attach (HANDOFF next step #7) |
| Mourner wraith thrall | `public/models/props/wraith_thrall.glb` (static; hover in code) | Mourner thralls (now the skeleton model made translucent). Register like `choir_wraith` in `modelPaths` | `EntityViews` / `modelPaths` |
| Lich Acolyte | `public/models/lich_acolyte/character.glb` (idle, walk, cast, hurt, death) | The last 0.4 enemy archetype: raises your fallen thralls against you (Nave + Sanctum) | Specced in [`agent-briefs/mobs-barrow-ghoul-lich-acolyte.md`](agent-briefs/mobs-barrow-ghoul-lich-acolyte.md) §3 |
| Barrow Ghoul (new, 2026-09-27 evening) | `public/models/barrow_ghoul/character.glb` (idle, walk, run, attack, dig, hurt, death; 4k tris) | Hollow Graves burrowing ambusher | Specced in [`agent-briefs/mobs-barrow-ghoul-lich-acolyte.md`](agent-briefs/mobs-barrow-ghoul-lich-acolyte.md) §2 |
| Area bosses (3) + portraits | `public/models/boss_{gravedigger_king,bone_abbess,drowned_congregation}/character.glb` (idle, walk, attack, cast or dig, hurt, death; 1024 px), `public/art/portraits/boss_{gravedigger_king,bone_abbess,drowned_congregation}.webp` | Bosses for the Hollow Graves, Marrow Ossuary and Drowned Nave | Boss brains + summoning |
| Future classes (5) + portraits | `public/models/hero_{grave_warden,bell_monk,carrion_witch,hollow_knight,veilwalker}/character.glb` (8 clips incl. `attack`), `public/art/portraits/{grave_warden,bell_monk,carrion_witch,hollow_knight,veilwalker}.webp` | Release 0.3 classes | Server class-index extension + discipline defs |
| Future spell icons (9) | `public/art/abilities/necro-{bone-fan,veil-step,grave-offering,soul-chain,ivory-cleave,rally-the-dead,frost-wake,carrion-seed,rot-lance}.png` | `SPELL-VARIETY-PLAN.md` spells. Reconcile that plan with the shipped Grimoire first | Ability defs |
| Relic rune icons (11) | `public/art/items/rune_{splinter,marrow_tap,volley,ossuary_ring,impale,mass_grave,bone_colossus,creeping_rot,contagion,hollow_choir,requiem}.png` | Socketable spell modifiers (`server/proposals/relic-runes.md`) | Server `rune` item type |

## 3. Replay and world

| Art | Files | Intended use | Waiting on |
|---|---|---|---|
| Omen and daily-rite icons (4) | `public/art/omens/{blood_moon,drowned_week,tolling,daily_rite}.png` | Weekly world omens and daily rites | Replay features |
| Area moodboards (3) | `docs/art/areas/{plague_cloister,bell_tower,catacomb_depths}.webp` | Level-design reference for the 0.5+ areas (not in-game textures) | Area design |

## 4. Older art with no code reference

| Files | Notes |
|---|---|
| `public/art/status/{burning,renewal,scorched,triage,void-collapse}.png` | Earlier status set. Renewal could serve a heal-over-time |
| `public/art/textures/skull_wall.webp` | Loaded by WorldView as a texture set member; the scanner only lists it because its name is built at runtime |

## 5. Third-party VFX library (BinbunVFX, Godot 4): portable conversion complete, runtime pending

About 250 effect scenes cover fire, ice, poison, smoke, impact, magic areas/orbs/projectiles, beams,
portals, loot and muzzle flash, plus transition, sky, water, grass and toon shaders. The owner confirmed
the licence for this non-profit game on 2026-09-27. The raw packs are in `art-src/vendor/binbun/`
(gitignored); the source record is `art-manifest/binbun-vfx.json`.
The workstation converter now ships a curated first batch of 22 effects in `public/fx/binbun/` (2.1 MB,
93 files): spell impacts/areas, candle, gate, beam, all seven loot tiers, and supporting textures and
include-expanded shader sources. The portable JSON retains the Godot scene/resource graph, sampled curves,
procedural definitions and default colours. It does **not** render yet; the Three.js runtime, shader translation,
gallery and game wiring remain a cloud-safe code follow-up. Rebuild locally with `npm run build:vfx` and verify
with `npm run test:vfx`.

**Second batch (2026-09-27, evening): 45 more, 67 in total (6.6 MB).**
- New rites (11): `bone_fan_hit`, `rot_lance_projectile`, `ivory_cleave_hit`, `grave_offering_orb`/`_ripple`,
  `rally_area`, `rally_thrall_rim`, `carrion_seed_armed`/`_burst`, `veil_step_trail`, `frost_shard_hit`.
- Interactable beacons (4): `interact_rim`, `altar_beacon`, `waystone_portal`, `recall_portal`.
- World ambience (10): fires, mists, fog, toxic pools, soul orb, level-up pillar, thrall rise.
- Enemies and bosses (9) and existing-spell layers (4).
- Seven `world_*` shader kits (water ×2, grass + ground, two screen transitions, dark sky). These are material roots
  with no nodes; the selection schema now accepts `.tres`.

New tintable sprites for the rites: `public/art/fx/{crescent,seed-bud,wisp,rally-sigil,veil-streak}.png` (Gemini,
`gemini-jobs/spells-v5.json`). The rite icons already existed (`future-2d.json`). Every hook is listed in
[`agent-briefs/spell-variety-first-session.md`](agent-briefs/spell-variety-first-session.md) §5.
**Status (2026-09-27 late):** the five sprites and seven icons are wired (`fxImages.ts`, the §4 rites). The Binbun
entries play through the new runtime (`src/graphics/binbun/`, DEV `vfxGallery`) but are **not yet hooked into
gameplay**. The `world_*` kits are unported.

**Plan, format notes and the proposed wiring:** [`BINBUN-VFX-PORT.md`](BINBUN-VFX-PORT.md).

## 6. Spend ledger (Tripo credits, 2026-09-27)

| Batch | Credits |
|---|---|
| Enemy pack: censer_bearer, choir_wraith, skull_rat, bone_golem | 395 |
| Professions node props (14) | 700 |
| Hero `slash` clip ×5 | 50 |
| Tools (4) + thrall gear (2) + wraith thrall + 5 more props + 8 profession props | 20 × 50 = 1,000 |
| Lich Acolyte (125), 3 bosses (3 × 145), 5 future class heroes (5 × 165) | 1,385 |
| Barrow Ghoul (evening; idle, walk, run, slash, dig, hurt, fall) | 145 |
| Boss props: kings_grave, abbess_reliquary, skull_niche, drowned_font, church_pew (5 × 50) | 250 |
| **Total 2026-09-27** | **3,925** (balance 5,155 → 1,230) |

Gemini (2D) runs are cheap and not itemised. Every output is recorded in `art-manifest/images.json`.
