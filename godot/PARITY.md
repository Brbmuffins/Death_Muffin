# Feature parity: current client (`godot-port`) vs the rebuild (`godot-next`)

Audited at `godot-next` 22ee59f3 (worktree branch `godot/parity-audit`), 2026-10-06. Read-only audit: nothing here was run for load; every
status comes from reading the code and READMEs named in the row. Paths are relative to `godot/` unless they start with `src/` (web) or `docs/`.
Current game = the `DmGame` hub (`game/`), `game_ui/`, `ui/`, `main/`, `front/`, `net/`, `sim/`. Rebuild = `next/` (`DmNextGame`), `enemies/`,
`session/`, `net/relay/`, per `REBUILD.md` (D1-D9).

Status key: **DONE** (equivalent behaviour on the rebuild), **PARTIAL** (what is missing is stated), **MISSING** (not on the rebuild, no decision drops it),
**N/A** (deliberately dropped, with the decision), **IN PROGRESS** (a track is landing it; not in 22ee59f3, per the integrator: Abbess / Congregation / Prelate,
the Depths, gathering).

How the rebuild reaches the UI: `DmNextGame` runs the *existing* `DmGameUi` through `DmNextUiHost` (`next/hud/dm_next_ui_host.gd`), an adapter that implements
the `GAME_CONTRACT.md` surface. So every panel and HUD widget "exists" on the rebuild; the question per row is whether the host feeds it. Contract methods
`DmNextUiHost` does **not** implement (current `DmGame` does): `stop_gathering`, `afk_active/afk_status/start_afk`, `dial_wave`, `party_create/join/leave`,
`summon_boss(_empowered)`, `enter_depths`, `class_changed`, `counsel_busy`, `counsel_tick_ctx`, `do_ascend/do_swear/do_open`, `apply_cosmetics`, `set_primary`,
`talk_to` (hub covers it), `belt_choices`, `pause/resume_coop`, `hitstop`. `DmGameUi` calls them through `has_method`, so they silently do nothing.
Also: `hud_state()` on the rebuild (`next/hud/dm_next_hud_vm.gd`) never sets `chain`, `omen`, `depth`, `next`, `save`, `ward`, `auto_combat`, `souls` (hard 0/10).

## Summary

**Rows audited: 207.** DONE 84, PARTIAL 56, MISSING 47, IN PROGRESS 11 (Abbess/Congregation/Prelate, Depths, gathering/laborers/garden, Acre ledger, depth prompt/readout),
N/A 9 (decisions D2/D3/D6/D9, bit-exact math, Socket.IO). The simulation core (rites, enemies, corpses, thralls, statuses, areas, waves, surges, 4 of 7 bosses, rewards, persistence,
audio/VFX reuse) is at or near parity and mostly better tested than before. What is not at parity is the **shell around it**: the front flow, hero presentation, settings consumers,
HUD feeds and contract methods that `DmGame` had and `DmNextGame` / `DmNextUiHost` do not. Most "PARTIAL" panels open (the UI is the old `DmGameUi`) but are fed nothing or untested.

### The 10 most important MISSING / PARTIAL items for a player (priority order)

1. **Front flow on the rebuild (DONE, godot/next-front).** `-- --next` (or `DmMain.USE_NEXT`) routes DmFrontFlow's "Enter world" to `DmNextGame` behind the key-art `DmLoadingScreen`: login/register (online) or the offline edition entry, discipline select, log out, class change (re-enter), quit save (`DmMain.save_all`). Tests `tests/next_front`. `-- --old` forces DmGame. Left: Play Online on the rebuild is untested against the live backend.
2. **Performance controls absent (MISSING).** No resolution governor, no FPS cap, no graphics presets (only `vfx.quality`), no loading cover, no GPU shader warm-up of models (`DmWarmup` not run),
   settings `fps` / `auto_res` / `graphics` inert. Owner priority #1; REBUILD Phase 6 plans the replacement but today the slice has no pacing safety net. (sections 17, 23)
3. **Necromancer combat feel (DONE on `godot/next-feel`, see `next/feel/README.md`; only Easy auto-combat and standing mouse-aim facing remain; original gap text follows).** Clicking a far enemy does nothing (no attack-target chase, no hold-LMB / Shift+LMB, no queued or held-key casts, out-of-range refusal is silent),
   the hero never plays a cast gesture (`avatar.cast` is never called by rites), and there is no hitstop. Rune choices never reach the caster (`rite_build()` sets `runes = {}`), so Hollow Choir / Requiem / Impaling /
   Mass Grave / Colossus builds are dead. (section 1)
4. **Difficulty, ascension rank and omen are not applied (MISSING).** `settings.difficulty` is stored but rewards/bosses/director use a constant "medium"; `DmSessionRewards.ascension` stays 0; omen multipliers have no source.
   The Altar (`do_ascend/do_swear/do_open`) has no host methods. Progression depth beyond XP/tiers is flat. (sections 2, 13)
5. **Hero looks naked (MISSING).** Worn gear, helm / hide-helm, legendary aura, capes, pets and the hero ring/halo are never applied (`avatar.set_equipment` / `set_cape` / `DmPetView` not called); the Capes & Pets
   panel changes nothing in the world. Hurts gear reward feedback and "immersive" feel. (sections 11, 19)
6. **Elite affixes missing (MISSING).** Bell-Tolled, Hungering, Shrouded, Vengeful, their rings and target-frame chips do not exist on `DmEnemy` (`enemies/dm_enemy.gd:68`). Hungering / Vengeful are the corpse-economy
   counterplay that makes the necromancer loop interesting. (section 2)
7. **Gathering, professions, laborers, garden, contracts (IN PROGRESS).** Whole Acre loop (nodes, AFK, laborers, charms, gather sfx, hover tips) is not on the rebuild; `DmNextUiHost` lacks
   `stop_gathering/afk_*`. Also in progress: the Depths (generated floors, stair prompt, readout), and Bone Abbess / Drowned Congregation / Bell-Sworn Prelate. (sections 3, 8, 9)
8. **HUD feeds missing (MISSING).** Kill chain meter and tier banners, Soul Harvest meter (hard 0), omen chip, Bone Ward chip, save-state chip, wave dial (`dial_wave`), auto-combat button
   (and Easy Auto Combat / auto-dodge themselves). Also loot / coin / rarity sounds and the hero hurt sound are not forwarded. (sections 1, 13, 16, 18)
9. **Boss meta-progression (MISSING).** Empowered summons + Covenant Seal + prize claim and the boss key prompt, first-kill trophies persisted (`trophy_store` unset), Chronicle (life records for the Codex),
   Codex "dead" discoveries, Nightfall / wave-milestone variants. (sections 3, 6, 13)
10. **Counsel and guidance state (PARTIAL).** `counsel_busy` / `counsel_tick_ctx` are not implemented, so state-based tips and in-combat tip suppression do not run; Next box and chat are solo stubs;
    Legion tier cannot be bought; Forge / Vault / Reagent shelf / Contracts / Sheet / Ascension panels open but are untested on the slice (only Bag, Grimoire, Settings are pre-built and tested). (sections 14, 15)

Lower priority, listed in the body: the five non-necromancer disciplines (rite registry is necromancer-only), lifesteal / fortune / wisdom brews, party/lobby UI (D5), remote players' gear/HUD, reconnect.


---

## 1. Combat and rites

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| 24 necromancer rites (needle, fan, rot lance, marrow spear, exhume, miasma, litany, corpse explosion, skull, step, frost, mantle, offering, cleave, veil step, rally, seed, siphon, prison, hands, storm + 4 signatures) | DONE | `game/dm_ability_system.gd`, `sim/sim_caster.gd` | `next/rites/rite_*.gd` (all 25 ids incl. `ossuary_wall`, `command_rend`, `dirge`, `plague_bloom`), `next/rites/README.md`; host-validated intents (D1) |
| Rite numbers, costs, cooldowns, essence, locks by level | DONE | `rules/combat/dm_abilities.gd` | same `DmAbilities` / `DmSimData`; `DmRiteCaster.request_cast` |
| Four disciplines' mods (Ossuary ward per thrall, Gravecaller champion/rend, Mourner corpse-heal, Rotweaver burst) | DONE | `data/content/disciplines.json`, `DmCharacterBuild` | `DmHeroBody.mods`, signatures per `next/rites/README.md` |
| Rune variants per rite (Hollow Choir, Requiem, Ossuary Ring, Impaling, Mass Grave, Colossus...) | PARTIAL | `rules/` runes, `DmCharacterBuild` | `DmNextGame.rite_build()` sets `out["runes"] = {}`: relic runes are never passed to the caster (rune choices in Grimoire do nothing). Mods from boons/vows are applied |
| Hotbar: keys 1-4, RMB (5), R signature (6), LMB primary, Grimoire loadout / loadout presets | DONE | `game/dm_loadout.gd`, `game_ui/dm_loadout_presets.gd` | `DmNextUiHost.rite_at/cast/set_rites` + `DmLoadout`; `next/rites/dm_rite_hotbar.gd` |
| Click an enemy = walk into range + primary attack (attack-target chase), hold LMB / Shift+LMB, held number keys | MISSING | `game/dm_game_input.gd` `update_attack_target`, `tick_combat` | `next/next_input.gd` casts the primary once on click; out-of-range is a silent refusal (`DmNextUiHost._on_rejected` ignores `range`/`no_target`). No chase, no hold-repeat |
| Queued casts (cast fires when the previous cast finishes) | MISSING | `dm_game_input.gd tick_combat` | caster refuses `busy` silently |
| Easy Auto Combat (G, owner-only gate) + auto-dodge | MISSING | `game/dm_auto_combat.gd`, `dm_auto_dodge.gd`, `dm_boss_telegraphs.gd` | `DmNextUiHost.set_auto_combat` only stores the setting; nothing runs it (`next/hud/README.md` "No auto-combat") |
| Hero cast gesture / weapon clips per rite (`castClips.json`) | MISSING | `game/dm_avatar.gd cast()`, `dm_ability_system.gd` | `DmRiteCaster` / rites never call `avatar.cast`; hero only plays idle/walk/dig(raise)/hurt/death (`DmHeroBody._process`) |
| Hitstop on heavy hits / elite deaths | MISSING | `game/dm_hitstop.gd` | `DmEnemyFx.host.hitstop_cb` and boss `hitstop` callback are unset (`next/enemy_fx/README.md`, `next/bosses/README.md`) |
| Camera shake on rites | PARTIAL | `main/camera_rig.gd` | `shake_requested` seam in `dm_rite_hotbar.gd`; boss/enemy fx shake via `host.camera`; rite shake wiring not confirmed |
| Hero hurt flash, floating damage/crit/DoT/thrall numbers (Settings: damage numbers) | DONE | `dm_event_fx.gd`, `dm_game_combat.gd` | `DmNextUiHost` (`hit_number`, `_on_hurt`, `watch_enemy`) |
| Cast feedback texts (essence/cooldown/locked) + `essence_short` counsel | DONE | `dm_game_input.gd feedback` | `DmNextUiHost._on_rejected` (rate-limited 600 ms) |
| Chill/root/stun/drag floats over hero, Bulwark/ward/barrier on hurt | PARTIAL | `dm_game_combat.gd on_hurt` | chill/root/stun/dragged floats + `_ward` in `DmHeroBody.take_damage`; Bulwark (knight family) not present |
| Other 5 disciplines (Hollow Knight, Grave Warden, Bell Monk, Carrion Witch, Veilwalker): kit rites (flail, toll, hook, crow, veil...) | MISSING | `data/content/abilities.json`, `kits.json`, `rules/` | `next/rites/dm_rite_registry.gd` is necromancer-only; a non-necro kit rite is refused `unavailable`. `DmHeroBody.family` exists. Owner priority: necromancer first, so low |
| Monk beat meter, Soul Harvest meter (souls), Bone Ward chip | MISSING | `dm_game_input.gd tick_chain_and_beat`, `dm_game_rewards.gd on_souls_charged` | `hud_state` hard-codes `souls: 0`; no beat/ward chip |
| Legendary gear mechanics (sync_legend: thrallDeathBurst, championEvery...) | PARTIAL | `dm_game_combat.gd sync_legend`, `DmLegend` | `DmThrallHost.legend` consumes `DmLegend` mods; whether the shell feeds worn legendaries each refresh is not shown in `DmNextGame` (grep: no `sync_legend` equivalent) |
| Bonded Dead boon (thrall rises on area entry) | MISSING | `dm_game_combat.gd tick_bond` | `DmThrallHost.raise_bonded` exists, but nothing in the shell triggers it |

## 2. Enemies

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| 27 enemy kinds (rat, hound, robber, ghoul, bat, moth, sac, wraith, golem, censer, penitent, templar, acolyte, deacon, seraph, gargoyle, flagellant, plague doctor, cinder husk, cinderhound, slag brute, pyre priest, mire leech, bog hag, fen wisp, drowned sexton, risen) | DONE | `sim/sim_enemy*.gd`, `game/dm_creature.gd` | `enemies/<id>.tscn` all 27 + `dm_enemy.gd`, `enemies/states/`, `enemies/kinds/` (state machines + NavigationAgent3D) |
| `niche` (boss add spawner) | N/A | `enemies.json` | handled as boss add spawn via director; no scene needed |
| Special AI (burrow/dig, flank, kite, unbind, sanctify, shield glance, censer pulse, hook, flask, scream, ember lob) | DONE | `sim/sim_enemy_ai.gd` | `enemies/kinds/*`, `enemies/states/*`; cues replicated by `next/next_net.gd` (`CUES`) |
| Bit-exact sim math / fdlibm determinism | N/A | `sim/fdlibm.gd`, `sim_exact.gd`, `game/dm_fdlibm_x.gd` | dropped: REBUILD "Enemies, AI, navigation: REFACTOR -> REBUILD ... drop bit-exact math"; D1 host-authoritative |
| Elite multipliers (hp/damage/scale, faster wind-up) | DONE | `sim/sim_data.gd ELITE` | `DmEnemy.elite` |
| Elite affixes (Bell-Tolled, Hungering, Shrouded, Vengeful) + affix rings/target-frame affix chips | MISSING | `rules/combat/dm_affixes.gd`, `data/combat/affixes.json`, `game/dm_entity_views.gd` | `enemies/dm_enemy.gd:68` "affixes are NOT implemented"; `next/enemy_fx/README.md` "Not covered: elite affixes". `DmStatusSet` has `shrouded` but nothing applies it |
| Enemy level scaling by area/hero level, wave-tier hp/damage ramp, difficulty hp/damage multipliers | PARTIAL | `sim_director.gd`, `DmEnemyStats` | `DmEnemyStats.area_level`, `ramp_tier` used by `dm_wave_director.gd`; **difficulty (Easy/Medium/Hard) is not applied**: `DmSessionRewards.difficulty` and `DmBossHost.difficulty` are constants "medium", nothing reads `settings.difficulty` |
| Enemy hit/death/windup/voice sfx, telegraphs, hostile zones | DONE | `dm_event_fx*.gd` | `next/enemy_fx/` (`DmEnemyFx`, replicated once per peer) |
| Enemy idle fx (rising dust, hover motes, fen/fire per-kind idle) | PARTIAL | `dm_entity_views.gd` | `next/enemy_fx/README.md` "per-kind idle fx of kinds that have no scene yet" (all kinds now have scenes; idle motes status unverified) |
| Pooled creature bodies / shared materials | PARTIAL | `dm_entity_views.gd`, `dm_creature_mat.gd` | `director.warm(true)` preloads kinds; no body pool equivalent found; `DmCreature` / `dm_creature_mat.gd` reused |

## 3. Bosses

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Boss framework (brain, telegraph, phases 60/30 %, stagger, wipe reset, leash, view, fx, hp bar, minimap dot, boss music, E to summon) | DONE | `sim/boss_controller.gd`, `sim/bosses/*`, `game/dm_boss_view.gd` | `next/bosses/` (reuses the 7 `DmBossBrain`s on `DmBossNodeWorld`) |
| Gravedigger King (Hollow Graves) | DONE | `sim/bosses/` | `next/bosses/README.md` + `tests/next_bosses/run.gd` |
| Plague Saint (Cloister), Cinder Regent (Pyre), Mire Mother (Fen) | DONE | same | `tests/next_bosses/{saint,regent,mire}_run.gd` |
| Bone Abbess (Ossuary), Drowned Congregation (Nave), Bell-Sworn Prelate (Sanctum) | IN PROGRESS | `sim/bosses/` | boss track; hooks stubbed (`dm_boss_node_world.gd` `cover()`, `echoes()`); Prelate summons by bell/`spend_shards`; the Sanctum has no boss area in the slice |
| Boss rewards, first-kill trophy (+2 shards, rare relic), relic rune, reporter `boss` entry | PARTIAL | `dm_game_rewards.gd on_boss_defeated` | `DmSessionRewards.on_boss_defeated`; trophies in memory per session unless `trophy_store` is set by the shell (it is not) |
| Empowered summons (Covenant Seal + gold), empowered prize claim, boss-busy refunds, boss key prompt | MISSING | `dm_game_actions.gd call_empowered`, `dm_game_rewards.gd claim_empowered`, `game_ui/dm_boss_key_prompt.gd` | `next/bosses/README.md` "Gaps"; `DmNextUiHost` has no `summon_boss(_empowered)` |
| Boss slow/root statuses, hitstop on boss hits | MISSING | `dm_boss_view.gd` | ignored by brain (README "Gaps"); hitstop callback unset |
| Boss spawn hint prompts / altar clicks | DONE | `dm_game_actions.gd interact` | `DmChapterhouse.interacted` -> `bosses.request_summon`, E key |

## 4. Thralls and corpses

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Corpse field (lifetime 26 s, cap 45, echo, toxic rupture, atomic consume, wisps, burst) | DONE | `sim/sim_corpse.gd`, `dm_event_fx*.gd` | `next/corpses/dm_corpse_field.gd` |
| Thralls: 8 kinds (warrior, shieldbearer, hound, wraith, archer, bone mage, plague bearer, colossus), follow/formation, cap, make-room, decay, rally, rend, sacrifice, plague burst | DONE | `sim/sim_thrall*.gd`, `game/dm_entity_views.gd` | `next/thralls/` (`DmThrall`, `DmThrallHost`, 15 Hz replication) |
| Enemies target thralls (weights) | DONE | `sim_enemy_ai.gd pick_target` | `dm_target_weight()` in `DmThrall` |
| Legion tier purchase (Legion panel Y), Legion gear kit (thrall weapons/armour) visuals | PARTIAL | `game_ui/dm_legion_text.gd`, `ui/panels_a/dm_legion_view.gd`, `game/dm_gear_props.gd` | thrall props/rim from `DmEntityViews` reused (`next/thralls/README.md`); "Legion tier is not bought in the slice" (`next/hud/README.md`) |
| Corpse-eating enemy AI (deacon/hungering) | PARTIAL | `sim_enemy_ai.gd` | `raised` supported; hungering affix missing (see Enemies) |
| Thrall hurt/crumble sounds | DONE | `dm_event_fx.gd` | `dm_thrall.gd` `thrallRise/thrallDeath` |

## 5. Statuses

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| slow, chill, root, stun, silence, bleed, withered, fracture, hex, sanctified, incensed, frenzy, shrouded, barrier | DONE | `sim/sim_*`, `DmEntityViews` motes | `next/status/dm_status_set.gd` (replicated 4 B/status, visuals via Vfx) |
| Player-side Bone Ward / Colossus guard as timed statuses; shrouded suspension in own Miasma | PARTIAL | `DmPlayerRules` | stat-based only (`next/status/README.md` "Gaps") |
| Brews: damage, haste, ward, speed, essence | DONE | `rules/.../dm_brews.gd` | `DmNextBelt` via `p["brews"]` |
| Brews: lifesteal, fortune, wisdom | MISSING | `dm_brews.gd` | "not applied yet" (`next/hud/README.md`) |

## 6. Areas and travel

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| 12 walkable areas built (Chapterhouse, Acre, Graves, Ossuary, Nave, Sanctum, Cloister, Pyre, Wing, Warren, Coliseum, Fen), streaming, fog, lighting, navmesh per area/door | DONE | `world/world_builder.gd` | `next/next_world.gd` (same builder), `areas/README.md` |
| Seals / doors / gates, kill-based unlocks (Warren 150 Graves kills, Swift Seals) | DONE | `dm_game_rewards.gd check_unlocks` | `DmChapterhouse.check_seals/apply_seals` |
| Waystone travel, T recall, minimap click travel, Waystone map panel (M) | DONE | `dm_game_actions.gd travel/start_recall` | `DmChapterhouse.travel/start_recall`, `DmNextUiHost.navigate`; host-only teleport (README gap) |
| Entry banners, first-entry Codex area discovery, first-entry counsel | DONE | `dm_game.gd _enter_area` | `next/areas/dm_area_flow.gd` |
| Omen sky tint + fog in hunting grounds | MISSING | `dm_game.gd _omen_light`, `_omen_for` | not in `next/` |
| Nightfall light dimming, wave-milestone banners (Elite Vanguard, Restless Crypts, Nightfall) | MISSING | `dm_game_rewards.gd tick_milestones` | `next/areas/README.md` "Nightfall shroud / vanguard milestone variants are not ported" |
| Multi-area simultaneous waves for party members in different areas | PARTIAL | n/a (co-op shared sim) | one director = one area (`areas/README.md`); D5 solo first |
| Occlusion dither shaders on walls/props | DONE | `world/dm_occ_*.gdshader` | same builder |
| Catacomb Warren stair -> Depths | IN PROGRESS | `dm_depths_controller.gd` | Warren stair interactable present in hub data; see Depths |

## 7. Waves, Surges, Processions

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Area rosters, caps (GLOBAL_ENEMY_CAP 72), pacing, first wave 1.3x, elite bonus, packs, metas | DONE | `sim/sim_director.gd` | `next/spawn/dm_wave_director.gd` |
| Processions (WAVE_THEMES, 30 % from wave 2) + banner | DONE | `sim_director.gd` | director `_roll_theme`, `DmAreaFlow` |
| Grave Surges (crypt, 3 waves, Surge Quelled reward) | DONE | `sim_director.gd`, `dm_game_rewards.gd on_surge_cleared` | `next/areas/dm_grave_surge.gd`, `DmSessionRewards.on_surge_cleared` |
| Wave Speed dial (active tier +/-), Wave upgrade tiers | PARTIAL | `dm_game.gd dial_wave/set_wave_tier` | tiers bought + applied (`DmNextProgress`, `set_wave_tier`); `dial_wave` not implemented so the HUD dial buttons do nothing |
| Waves climb from area breaches | N/A | `world.json breaches` | slice uses a ring 9-14 m around the hero snapped to navmesh (areas README); Godot-idiomatic rebuild |

## 8. Depths (Catacomb Depths)

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Per-run generated floors, stairs, chest, depth rewards, depth readout, stair prompt, deepest-floor resume | IN PROGRESS | `game/dm_depths_controller.gd`, `sim/depths_floor.gd`, `sim_depths_rules.gd`, `game_ui/dm_depths_stair_prompt.gd` | depths track; `DmWaveDirector` skips `instance` areas; `DmNextUiHost.enter_depths` missing; HUD `depth` key unset |
| Depth kills reported to ledger (`report_floor`) | IN PROGRESS | `DmProgressSync.report_floor` | not wired |

## 9. Gathering, professions, laborers, garden, contracts

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Acre / Wing gathering nodes (view, hover tips, work loop, tool in hand, gather sfx, charms, AFK gather) | IN PROGRESS | `game/dm_game_gather.gd`, `dm_gather_loop.gd`, `dm_gather_session.gd`, `dm_skills.gd`, `dm_node_views.gd`, `audio/audio_gather_sfx.gd` | `next/areas/README.md` "Gathering ... is not wired"; `DmNextUiHost` lacks `stop_gathering/afk_*/start_afk` |
| Grave Laborers (visible laborers, collect, full notices) | IN PROGRESS | `game/dm_game_labor.gd`, `dm_laborer_views.gd` | not in `next/` |
| Garden (plant/harvest ready notices) | IN PROGRESS | `dm_game_labor.gd` | panel `ui/panels_b/dm_garden_panel.gd` opens at Acre station; world glue missing |
| Contracts panel | PARTIAL | `dm_game_labor.gd refresh_contracts`, `dm_contracts_panel.gd` | panel reachable via station (`station_interact`), untested; `refresh_contracts` glue absent |

## 10. Crafting, forge, reforge, salvage, alchemy

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Forge / Workbench (craft, reforge tab, salvage, reagent shelf, grinder range) | PARTIAL | `ui/panels_b/dm_forge_panel.gd`, `dm_reforge_view.gd`, `dm_salvage_panel.gd`, `dm_reagent_shelf_panel.gd`; `game/dm_game.gd near_grinder` | stations emit `station_interact` and `DmNextUiHost.near_grinder` is wired; `next/hud/README.md`: "open and work on the offline backend in principle but ... untested". Only Bag / Grimoire / Settings are pre-built (`SLICE_PANELS`) |
| Alchemist's Wing stations (cauldron, alembic, reagents), brews, meals | PARTIAL | `dm_game_actions.gd` | brews/meals/flasks DONE (`DmNextBelt`); Wing stations emit but untested |
| Gold sinks (reforge quotes, server-priced) via `spend_on_server` | PARTIAL | `DmProgressSync.spend_on_server` | `DmProgressSync` reused by `DmNextProgress`; reforge flow untested |

## 11. Inventory, bag, vault, equipment, visuals, cosmetics

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Reliquary (bag 24, equip slots, item cards/tooltips, locks, sort/Drink/Eat double-click, compare) | DONE | `ui/panels/dm_reliquary_panel.gd`, `game_ui/dm_ui_inventory.gd`, `game/dm_inventory.gd` | same classes via `DmNextUiHost.inventory`; pre-built under loading cover |
| Vault (shared storage, Chapterhouse only) | PARTIAL | `ui/panels_b/dm_vault_panel.gd` | station emits; panel untested (README) |
| Character stats from worn gear / set bonuses / affixes | DONE | `rules/gear`, `DmCharacterBuild` | `DmNextGame.build_for` + `DmNextProgress.request_stats` |
| Worn gear visible on the hero (weapons, off-hand, helm, hide-helm setting, class gear props) | MISSING | `game/dm_game.gd:414,534 avatar.set_equipment`, `dm_avatar.gd`, `dm_gear_props.gd` | rebuild never calls `avatar.set_equipment` (only `thralls` use `DmGearProps`) |
| Legendary aura on hero | MISSING | `dm_avatar.gd _legendary_aura` | needs `set_equipment` |
| Capes and pets (cosmetics panel N, Character sheet "Pets" tab), pet companion view, remote players' capes | MISSING | `game/dm_game.gd load_cosmetics/apply_cosmetics`, `dm_pet_view.gd`, `ui/panels_a/dm_cosmetics_view.gd` | `apply_cosmetics` absent; no `DmPetView`; panel opens but selection has no effect in world |
| Hero dressing (contact shadow, pale ring, discipline glow, reticle, soul halo, target ring) | MISSING | `dm_game.gd _dress_hero` | `next/README.md` "hero VFX decals (hero ring) from DmGame._dress_hero" left |
| Loot on ground (pickup 1.3 m, 60 s expiry, never flies, rarity beams, auto-loot rules) | DONE | `loot_view/`, `dm_game_rewards.gd` | `DmSessionRewards` + `DmLootView`; `loot_view.rules` from Settings -> Loot |
| Loot pickup/drop sounds (coin, drop, rarity) | MISSING | `dm_game_rewards.gd collected` | "not forwarded to the AudioDirector" (`next/hud/README.md`) |
| Reliquary full notice | DONE | `try_take` | `DmNextUiHost._take` |

## 12. Loot rules and settings

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Server-rolled gear (`roll_loot`), affixes, item level, `DmLoot.roll_kill/boss`, drop quality by depth, runes | DONE | `rules/loot`, `dm_game_rewards.gd drop_items` | `DmSessionRewards` -> `member.api.roll_loot` (D1: backend rolls) |
| Smart loot / loot filter / Settings -> Loot per-tier (ground/auto/gold) | DONE | `DmLootFilter`, `dm_settings.gd loot_rules` | `DmNextUiHost._apply_settings_side_effects` |
| Kill ledger batches (`session_report`) with sanity caps | DONE | `net/dm_kill_reporter.gd`, `DmProgressSync` | `DmSessionRewards` + `DmKillReporter` (superset: multi-member) |
| Gold pooled over N kills, new-blood XP catch-up, wisdom/fortune multipliers | DONE | `dm_game_rewards.gd` | `DmSessionRewards` / `DmRewardsMember` |

## 13. Progression

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| XP, levels (cap 999), level-up banner/heal/sound, new-rite toast | DONE | `DmProgression`, `dm_game_rewards.gd gain_xp` | `DmNextProgress` + `DmProgression` |
| Damage / Wave Speed upgrade tiers (Empower / Quicken) | DONE | `dm_game.gd buy_upgrade` | `DmNextProgress.buy` |
| Backend persistence cadence (urgent / 45 s / area change / quit) | DONE | `DmProgressSync` | reused unchanged; `flush_all` on window close (`main.gd`) |
| Boons / vows (stat effects) | DONE | `DmCharacterBuild` | `DmNextGame.build_for` includes boons/vows |
| Vows' world effects (Dry Cellar flask ban, Swift Seals, sync_world_vows) | PARTIAL | `dm_game.gd sync_world_vows` | Dry Cellar + Swift Seals honoured in belt/seals; other world vows not verified |
| Ascension (Altar: ascend, swear vows, open keys; reward/difficulty scaling by rank) | PARTIAL | `dm_game.gd do_ascend/do_swear/do_open`, `ui/panels_a/dm_ascension_panel.gd` | Altar station emits; `DmSessionRewards.ascension` stays 0.0 (never set from progress); `do_*` not on host |
| Omen (daily/rolling modifier: reward/shard mult, sky, chip) | MISSING | `dm_game.gd _omen_for/_omen_light`, HUD `omen` | `omen_reward/omen_shard` default 1.0, no source; HUD omen unset |
| Kill chain (tiers, bonus, break, HUD chain meter) | PARTIAL | `dm_game_rewards.gd on_chain_tier`, `DmKillChain` | `DmRewardsMember.chain` multiplies XP/gold; no tier banner/sfx, no HUD `chain` meter |
| Milestones (best chain, kills -> gold) | DONE | `check_milestones` | `DmNextProgress._check_milestones` (ground gold drop) |
| Trophies (first boss kill) | PARTIAL | `claim_trophy` | in-memory per session; `trophy_store` unset |
| Chronicle (life stats / records for the Codex "Chronicle" tab) | MISSING | `dm_game.gd _tick_chronicle/flush_chronicle` | not in `next/` (grep) |
| Codex (kills discovered, areas) | PARTIAL | `dm_game.gd codex_discover` | areas on entry (`DmAreaFlow`); "dead" (enemy kind first-sight/kill) discoveries not recorded |
| Leaderboard | MISSING | only `DmApi.get_leaderboard` (`net/dm_api.gd:506`); no panel in the current client either | the public website shows it; no in-game UI planned |
| Gear Atlas panel (.), Class panel (change discipline) | PARTIAL | `ui/panels_a/dm_atlas_panel.gd`, `dm_class_panel.gd` | atlas reads data (no game needed); Class change needs `class_changed` (absent) |

## 14. NPCs, dialogue, counsel, onboarding

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Hub NPCs (spots, talk range, "!" news marker, first-sight), E to talk | DONE | `game/dm_npc_views.gd`, `dm_game.gd _tick_npcs` | `next/chapterhouse/dm_hub_npcs.gd`, `DmChapterhouse.talk_key` (acre / wing NPCs only appear in their areas) |
| Covenant dialogue / guidance memory / Next box | PARTIAL | `ui/panels_a/dm_dialogue_panel.gd`, `game_ui/dm_game_ui.gd guidance_state` | dialogue panel works through `npc_interact`; Next box depends on bag/level only (`hud/README.md`) |
| Counsel tips (cadence, events, store, progressive HUD reveal, NEW cues) | PARTIAL | `ui/onboarding/`, `game_ui/dm_hud_reveal.gd` | UI side reused; `counsel_busy` / `counsel_tick_ctx` absent so state-based tips and in-combat suppression do not run; events emitted by DmNextProgress/Areas/UiHost only |
| First-hour guidance pings, `/party` etc. chat commands | PARTIAL | `game_ui/dm_chat_command.gd` | `send_chat` = "(solo) Nobody hears you" |

## 15. UI panels (one row per panel; all exist on the rebuild via `DmGameUi`, status = fed + reachable)

| Panel (key) | Status | Where | Rebuild note |
|---|---|---|---|
| Reliquary / bag (I, B) | DONE | `ui/panels/dm_reliquary_panel.gd` | pre-warmed, tested |
| Grimoire (L) + loadout presets + rune picks | PARTIAL | `ui/panels_a/dm_grimoire_*`, `game_ui/dm_loadout_presets.gd` | works; runes empty (see Combat) |
| Settings (Esc) | DONE | `ui/panels/dm_settings_panel.gd` | pre-warmed; some keys inert (section 19) |
| Character sheet (J) stats tab | PARTIAL | `ui/panels_a/dm_sheet_view.gd` | untested on slice |
| Capes & Pets (N, sheet tab) | MISSING | `dm_cosmetics_view.gd` | no `apply_cosmetics` |
| Legion (Y) | PARTIAL | `dm_legion_view.gd` | tier not purchasable |
| Forge / Workbench (C) incl. reforge, Salvage, Reagent shelf | PARTIAL | `ui/panels_b/*` | untested |
| Vault (V) | PARTIAL | `dm_vault_panel.gd` | untested |
| Acre ledger: Professions (P), Garden (U), Labor (H), Contracts (O), Gather report | IN PROGRESS | `dm_professions_panel.gd`, `dm_garden_panel.gd`, `dm_labor_panel.gd`, `dm_contracts_panel.gd`, `dm_gather_report_panel.gd`, `dm_acre_ledger.gd` | gathering track |
| Codex (K) | PARTIAL | `dm_codex_panel.gd` | areas only |
| Gear Atlas (.) | DONE | `dm_atlas_panel.gd` | data-only |
| Waystone map (M) | DONE | `dm_waystone_panel.gd` | via `travel` |
| Ascension / Altar | PARTIAL | `dm_ascension_panel.gd` | see Progression |
| Class panel | PARTIAL | `dm_class_panel.gd` | `class_changed` absent |
| Dialogue | DONE | `dm_dialogue_panel.gd` | NPC hub |
| Boss key prompt (Empowered choice) | MISSING | `game_ui/dm_boss_key_prompt.gd` | no summon methods |
| Depths stair prompt | IN PROGRESS | `game_ui/dm_depths_stair_prompt.gd` | depths track |
| Belt picker (Z/X slot) | DONE | `game_ui/dm_belt_picker.gd` | `DmNextBelt.load_pick/set_belt` |
| Bug report | PARTIAL | `game_ui/dm_bug_report_view.gd` | uses `ui.game.api.send_bug_report`; the adapter exposes `api`, so it should work: untested on the slice |
| Chat line / chat box | PARTIAL | `game_ui/dm_chat_command.gd` | local only |
| Spell tooltip, item tooltip, stat key | DONE | `game_ui/dm_spell_tooltip.gd`, `ui/widgets/dm_item_tooltip.gd` | |
| Keybind rebinding (loadout hotkeys) | DONE | `game_ui/dm_ui_binds.gd` | `DmGameUi._unhandled_key_input`; `DmKeybinds` (game) not used by rebuild: input actions registered at runtime by `DmNextInput` |

## 16. HUD widgets

| Widget | Status | Rebuild note |
|---|---|---|
| Health / resource orbs, level badge, XP bar | DONE | `DmNextHudVm` |
| Hotbar + cooldown sweep, primary socket, rune icon, locked/affordable | DONE | slots from `DmAbilities` |
| Belt chips (Q/Z/X), brew timers | DONE | `DmNextBelt.rows()` |
| Target frame (name, hp, statuses) | PARTIAL | no elite affix chips (affixes missing) |
| Boss bar (phases ticks 60/30 %) | DONE | `vm["boss"]` |
| Party frames | PARTIAL | roster-driven; client peers get no HUD yet |
| Minimap (enemies, thralls, corpses, doors, boss dot, click travel) | DONE | `DmHudMinimap` |
| Area label + progress | PARTIAL | label yes; Depths readout missing |
| Upgrade box (Empower/Quicken, dial) | PARTIAL | tiers yes; dial buttons dead (`dial_wave`) |
| Thrall pips / legion chip | DONE | |
| Soul Harvest meter | MISSING | `souls: 0` |
| Kill chain meter | MISSING | `chain` unset |
| Omen chip | MISSING | |
| Depth readout | IN PROGRESS | |
| Bone Ward chip | MISSING | |
| Auto-combat button | MISSING | |
| Next-step box, guidance ping, progressive reveal / NEW pips | PARTIAL | reveal logic in `DmGameUi` runs; Next box limited |
| Toasts, banners, loot toast, floating numbers, death wash, hit flash | DONE | |
| Save-state chip (`save` text/warn) | MISSING | not in vm |
| Node/laborer hover tip | IN PROGRESS | gathering |
| Interaction prompt + hover highlight | DONE | `DmChapterhouse` |

## 17. Settings keys (`game/dm_settings.gd`)

| Key | Status | Note |
|---|---|---|
| `vol_master/combat/amb/music/ui` | DONE | `AudioDirector.apply_settings` |
| `loot_<tier>` (5) | DONE | `loot_view.rules` |
| `damage_numbers` | DONE | `DmNextUiHost.float_text` |
| `reduce_motion` | DONE | Vfx + camera |
| `graphics` (high/low) | PARTIAL | only `vfx.quality`; no moon-shadow/bloom/prop-light changes (`DmGame._apply_graphics`); REBUILD Phase 6 plans presets |
| `fps` (Engine.max_fps), `auto_res` (resolution governor), `graphics_chosen` | MISSING | `DmGame._apply_render_scale/_apply_graphics`; nothing in `next/` |
| `difficulty` | MISSING | stored, never applied to waves/rewards/bosses |
| `auto_combat` / `auto_gather` | MISSING | stored, no consumer |
| `hide_helm` | MISSING | no gear on hero |
| `no_tips`, `guidance`, `guide_ping` | PARTIAL | consumed by `DmGameUi` counsel; busy ctx missing |
| `dev_access` | PARTIAL | `dev_access` var false on host; Settings toggle effects (`_apply_dev_access`) absent |
| Settings -> Leave / log out | PARTIAL | `leave_world` emits `left_world`; `main.gd` only handles it for `DmGame` |

## 18. Audio

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Music director (area cues, boss score, crossfades), zone ambience beds, accents | DONE | `audio/`, `main/audio_hooks.gd` | `DmAudioHooks` on `DmNextGame` (same autoload); every area has cue + bed (tested) |
| Footsteps by surface, wading | DONE | `audio_footsteps.gd` | `DmAudioHooks._footsteps` |
| Boss war-drum bed, boss music | DONE | `AudioDirector.set_boss_music` | `next/bosses/` |
| Enemy windup/strike/death/voice sfx | DONE | `dm_event_fx.gd` | `DmEnemyFx` |
| Rite sfx (needle, loops: miasma/siphon) | PARTIAL | `dm_ability_system.gd` | `DmRiteFx` carries sounds; per-rite coverage not individually verified (only 3 rite files mention audio) |
| Thrall rise/death, level-up, UI/panel sounds | DONE | | `dm_thrall.gd`, `DmNextProgress`, `DmGameUi.sound` |
| Loot, coin, rarity sounds; hero hurt sound; gather sfx family | MISSING | `audio_gather_sfx.gd`, `collected()` | not forwarded; gathering not wired; hero_hurt in `DmAudioHooks` static but unused by next |
| Co-op `partner` audio flag | N/A | `AudioDirector.partner` | D3 session model |

## 19. VFX

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Vfx autoload (Binbun effects, decals, beams, motifs, danger), `SPELL_FX` rite looks | DONE | `fx/` | reused unchanged (REBUILD "Assets rule"); `DmRiteFx` |
| Enemy telegraphs/strikes/deaths, hostile zones, boss telegraphs | DONE | `dm_event_fx*.gd` | `DmEnemyFx`, `DmBossFx` |
| Corpse wisps, rise/fall, status motes | DONE | | `next/corpses`, `next/status` |
| Hero ring / halo / reticle / target ring | MISSING | `_dress_hero` | see Inventory |
| Waystone ring/glow/portal/motes | DONE | `_dress_waystones` | `DmChapterhouse._dress_waystones` |
| Click-move marker | DONE | | `DmNextInput.click_move` |
| Omen sky tint, nightfall dimming | MISSING | | see Areas |
| Hitstop | MISSING | | see Combat |
| Graphics-quality scaling of effects (Low) | PARTIAL | | `vfx.quality` set |

## 20. Saves, accounts, front screens, launcher

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Login, register, resume token, claim_session | MISSING | `front/dm_front_flow.gd`, `dm_login_screen.gd` | `main.gd _next_slice` hard-codes account `tester` on the offline mock; `--next` skips `DmFrontFlow` |
| Character select / discipline card (create character) | PARTIAL | `front/dm_char_select_screen.gd` | slice takes `--class=N`; no select screen |
| Online mode (`--online`) with VPS backend | PARTIAL | `main.gd` | `_next_slice` uses whichever `api` exists; D8 says existing characters carry over; untested end-to-end |
| Offline edition (local backend `DmMockBackend`, separate characters) | DONE | `game/dm_offline.gd`, `net/dm_mock_backend.gd` | D4; `DmNextGame` takes `DmOffline.make_api` |
| Cloud saves: progress, necro, inventory | DONE | `DmProgressSync`, `DmInventory` | reused |
| Class change (rebuild world with new discipline) | MISSING | `dm_game.gd class_changed` | |
| Log out | MISSING | `dm_game.gd leave_world` | |
| Release watcher (web reload prompt) | N/A | `net/dm_release_watch.gd` | not ported in the current game either (`game/README.md`); launcher handles updates (`launcher/`) |
| Launcher hooks | N/A | `godot/` has none; `launcher/windows` is a separate app | |
| `flush_all` on window close | DONE | `main.gd _notification` | handles `slice` |
| F3 perf overlay | DONE | `main/perf_overlay.gd` | added in `main.gd` before either path |

## 21. Online / co-op

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Party of up to 10 on Socket.IO realtime, host migration, snapshots, remote players | N/A | `game/dm_game_coop.gd`, `net/realtime/` | replaced: D2 (4 players), D3 (listen-server + relay), D6 (host quits = session ends, no migration); Socket.IO retired |
| Session host/join, roster cap 4, body spawn, movement replication, enemy/corpse/thrall/status/boss replication | DONE | n/a | `session/dm_session.gd`, `next/next_net.gd`, per-subsystem replication; tests over ENet |
| Relay peer + lobby client | DONE | n/a | `net/relay/dm_relay_peer.gd`, `dm_lobby_client.gd`; server `server/death-muffin/lobby/` |
| Lobby UI (find/create/join, private codes) | MISSING | `/party` chat commands + party code | no UI; `party_*` absent (D5: online back seat) |
| Joiner gets a real HUD, real character handshake, own backend api for loot/XP | PARTIAL | | clients get no HUD (`hud: true` host only); remote `character_id` 0 until handshake; joiner loot lands unrolled |
| Remote players' gear/cape/pet display, party chat | MISSING | `dm_game_coop.gd dress_remote/chat_line` | |
| Reconnect / rejoin (10-minute window) | MISSING | `net/realtime/dm_rt_reconnector.gd`, `dm_rt_rejoin_store.gd` | D6: no migration; reconnect not planned |
| Session `session_open/report/end`, heartbeats | DONE | `net/dm_api.gd` | `DmSessionRewards` |

## 22. Bug report button and daily agent

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| HUD "Report a bug" button + Settings -> Report a bug form (`/api/bug-reports`) | PARTIAL | `game_ui/dm_bug_report_view.gd`, `ui/hud/dm_hud.gd` | UI + `api.send_bug_report` reused; reachable via `DmGameUi`; untested on the slice |
| Daily Claude triage agent, Discord "fixed - live now" alerts | N/A | server side | unaffected (backend/server) |

## 23. Perf features

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Load-time warm-up (models, Binbun effects, shaders, pooled bodies) | PARTIAL | `game/dm_warmup.gd` | `director.warm(true)`, `DmRiteFx.warm`, `enemy_fx.warm`, `bosses.warm`, `ui.warm()`; **no GPU shader pass for models** ("a first-draw shader compile can still hitch once", `next/README.md`) and `DmWarmup` is not run |
| Loading screen with progress | MISSING | `game/dm_warmup.gd` under cover, `main.gd` | `DmNextGame.start()` is awaited but no loading cover is shown by `_next_slice` |
| Resolution governor (auto-res, min 0.6) | MISSING | `game/dm_resolution_governor.gd`, `dm_game.gd _apply_render_scale` | not wired. REBUILD Phase 6 intends to change it (floor ~0.85, presets) |
| FPS cap / graphics presets | MISSING | `_apply_graphics` | Phase 6 |
| Effect/pool budgets (Vfx pools, decal layers), per-frame cost discipline | DONE | `fx/` | reused; per-track perf budgets in `tests/next*` |
| Event-driven / throttled systems (corpse expiry, 10 Hz hub tick, 20 Hz net only with peers) | DONE (new) | | the rebuild's stated perf rule |
| Navmesh-based enemies (replaces custom nav) | DONE (new) | `sim/nav.gd` | `next/next_world.gd` ~130 ms bake |

## 24. Anything else

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Hero death -> respawn in Chapterhouse (4 s), death veil | DONE | `dm_game.gd respawn` | `DmHeroBody.RESPAWN_S` |
| Bone Grinder, Lectern, Sawpit, Kiln, Fire stations | PARTIAL | `dm_game_actions.gd interact` | `DmChapterhouse.interact` handles stations; Acre stations "open but persistence is the progression track's" |
| Boss summon in-world prompts, Next-step guidance ping | PARTIAL | | see above |
| Dev tools (F9 break seals, `__cwDebug`, QA driver) | PARTIAL | `main/qa_driver.gd` | not ported to slice; DEV account gating partial |
| Tests: rules suites, session/relay/rites/status/corpses/thralls/areas/bosses/hud/progress | DONE | `tests/` | `tools/godot/run-all-tests.sh` |
| Mobile build / web build | N/A | | D9 web retirement; mobile not in Godot scope |
