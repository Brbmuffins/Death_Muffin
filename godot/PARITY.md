# Feature parity: current client (`godot-port`) vs the rebuild (`godot-next`)

Re-audited at `godot-next` 569894df (branch `godot/parity-audit-2`), 2026-10-06; the first pass was at 22ee59f3 and went stale as the tracks landed.
**Partial re-audit 2026-10-08 (branch `next/sync-1008`, after merging `godot-port` into the rebuild line):** only the rows touched by that sync and the open-gaps list were re-checked
(marked "sync-1008" below: graphics presets + lift, Brightness, Interface size / canvas stretch, the staff online gate, the waystones GM rule, spawn-outside-aggro, reconnect).
**Every other row is as of 569894df and was NOT re-checked in this pass.** Suites run for the sync: the whole `tools/godot/run-all-tests.sh` (see the REBUILD.md status). Every
row that was not DONE / N/A was re-checked against the code, the track READMEs and the suites on this branch. Paths are relative to `godot/` unless they start with
`src/` (web) or `docs/`. Suites re-run for this pass: `tests/next_hud_counsel` (94 pass), `tests/next_boss_meta` (61 pass); other citations are from reading the
code / the test's checks, not from a run. Current game = the `DmGame` hub (`game/`), `game_ui/`, `ui/`, `main/`, `front/`, `net/`, `sim/`. Rebuild = `next/` (`DmNextGame`),
`enemies/`, `session/`, `net/relay/`, per `REBUILD.md` (D1-D9).

Status key: **DONE** (equivalent behaviour on the rebuild, cited), **PARTIAL** (what is missing is stated), **MISSING** (not on the rebuild, no decision drops it),
**N/A** (deliberately dropped, with the decision). "unverified" = code seen but no test or run confirms it.

How the rebuild reaches the UI: `DmNextGame` runs the *existing* `DmGameUi` through `DmNextUiHost` (`next/hud/dm_next_ui_host.gd`), an adapter that implements
the `GAME_CONTRACT.md` surface. So every panel and HUD widget "exists" on the rebuild; the question per row is whether the host feeds it. The adapter now implements
every contract method the first audit listed as absent (`stop_gathering`, `afk_*`, `start_afk`, `dial_wave`, `summon_boss(_empowered)`, `enter_depths`, `class_changed`,
`counsel_busy`, `counsel_tick_ctx`, `leave_world`, `flush_chronicle`) except `pause/resume_coop`, `belt_choices`
(`DmNextBelt` serves it) and `set_primary` (`set_rites` covers it); the party calls (`party_view/watch/refresh/create/join/join_id/leave/kick/set_open`) are served by `DmNextParty` (`next/party/`).
`hud_state()` (`next/hud/dm_next_hud_vm.gd`) now sets `depth`, `chain`, `omen`, `ward`, `souls` and `save` (the auto-combat button follows the `auto_combat` setting); `next` (Next-step box) follows the guidance feeds and `minimap.ping` the suggestion (`tests/next_acre_guide`).

**Not the default yet:** `DmMain.USE_NEXT` is still `false` (`main/main.gd:12`); the rebuild runs with `-- --next`, the old game stays the default until the owner flips it.

## Open gaps, ranked

Ranked by owner priority: performance #1; the necromancer's four disciplines and combat / loot / first-hour polish; online is a back seat (D5); the five other disciplines are low.

1. **Performance, rendered (not headless).** All the rebuild's numbers are headless on a shared VPS (frame median ~7.3 ms); no GPU-measured pass of the rebuilt scene exists. **sync-1008:** Phase 6 (presets Low / Medium / High / Ultra with per-preset brightness lift, floor 0.85, Ultra-only MSAA, anisotropic textures, sharper ground markings, lighting lift + Brightness, canvas_items UI scaling) is now on the rebuild path too: `DmNextPerf` applies the same table and `DmWorldBuilder` is shared (`tests/next_perfctl`). What is missing is a rendered frame budget on real hardware (and the Forward+ evaluation, which needs the owner's and Helix's PCs).
2. **Target-frame affix chips (DONE, `tests/next_brews_affix`)**: `DmNextHudVm._target` feeds `{id, name}` chips + the combined blurb from the replicated `dm_affix_list` meta, cached per target.
3. **Lifesteal / fortune / wisdom brews (DONE, `tests/next_brews_affix`)**: `DmRewardsMember.sync_brews` sets wisdom / fortune per kill from the body's active brews; `DmSessionRewards` applies `DmBrews.lifesteal_heal` on every host-side hit the hero lands.
4. ~~**Gathering world glue**~~ **CLOSED** (`DmNextAcre`, `tests/next_acre_guide`): visible Grave Laborers, labor / garden / contract notices, collect / contract gold credited. Gather bests are stored (`dm_gather_best_v1:<id>`, `tests/next_polish`).
5. ~~**First-hour guidance**~~ **CLOSED** (`tests/next_acre_guide`): the Next box + ping are fed the current client's state (and skills / trophies / labor / contracts), the reforge flow, Wing and Acre stations and the bug report are verified (the reforge gold and the contract / labor gold bugs were fixed on the way). Left: a few counsel events still unraised (`next/hud/README.md`).
6. ~~**Combat odds and ends**~~ **CLOSED** (`tests/next_combat_odds`): the brief was partly stale. Player-side Bone Ward / Colossus guard were already the current client's own rule (stat-based on hit, never timed statuses); boss slow / root are ignored by the current client too (bosses are immune), so the rebuild already matched, now locked by a test; rite sfx are verified for all 25 rites against the current client's recorded sounds; the real gap was the necromancer's **weapon-line primaries** (staff pierce, sickle Withered, scythe arc + its soul window), built now. Bulwark stays N/A until a non-necromancer kit exists (gap 10). Pooled creature bodies: still moot (enemies are scenes).
7. ~~Rune variants / Grimoire runes / legendary mechanics / Bonded Dead~~ DONE (`tests/next_runes`). Left: a joined client's own rune sockets do not reach the host (D5); Colossus Mantle hooks are host-hero only. (Splinters / Volley / Marrow-Tap now apply to the staff and scythe primaries as the current client does, `tests/next_combat_odds`.)
8. **Make the rebuild the default** (`USE_NEXT`) once the owner is satisfied; Play Online on the rebuild is verified solo against the live backend (`tests/online_live`, opt-in); the staff online gate (D10) is live in both clients.
9. **Online (D5, back seat):** ~~lobby UI, client HUD / own backend api for joiners, party chat~~ DONE (`tests/next_lobby`, `next/party/README.md`). Left: reconnect (D13: owner wants a rejoin window, NOT built), multi-area waves for a split party, Depths for parties, a client's Covenant Seal / Nightfall dim, a joiner's own gear / upgrades reaching the host's sim, flasks and brews for a joiner.
10. **The five non-necromancer disciplines** (kit rites, monk beat meter, wraith nova): `DmRiteRegistry` is necromancer-only.

## Summary

**Rows counted: 210** (207 + 3 rows added by the 2026-10-08 sync: `brightness`, `ui_scale`, the staff online gate; all DONE. The 207 were 206 + the weapon-line row added by the combat-odds pass, which also moved boss slow / root and rite sfx to DONE). After the re-check (+ the polish pass: reveal / dev_access / dev tools closed): DONE 177 (174 + the 3 new rows; no existing row changed state, the graphics / spawn / waystone / reconnect rows only got text; the other counts are unchanged from 569894df and not re-counted), PARTIAL 18, MISSING 6, N/A 10, IN PROGRESS 0 (the acre-guide pass closed 12 rows: laborers, garden, contracts, Workbench / reforge, Wing stations, gold sinks, Next box, Acre ledger, the two bug-report rows, Acre stations, boss prompts + ping)
(first pass: DONE 84, PARTIAL 56, MISSING 47, IN PROGRESS 11, N/A 9). The simulation core, the shell around it (front flow, hero look, HUD feeds, settings consumers), the
meta layer (difficulty, vows, Omen, chain, Soul Harvest), all seven bosses with Empowered summons, the Depths, gathering, the Chronicle and Codex are on the rebuild
and covered by `tests/next_*`. What is left is the list above.

### The ten items of the first audit, as they stand

1. **Front flow (DONE, `tests/next_front`).** `-- --next` routes login / register / offline entry / discipline select / log out / class change / quit save into `DmNextGame` behind the key-art `DmLoadingScreen`. Left: Play Online on the rebuild is verified against the live backend (solo, `tests/online_live`); `USE_NEXT` still false.
2. **Performance controls (DONE, `tests/next_perfctl`).** `DmNextPerf` (graphics, fps cap, resolution governor) and `DmNextWarmup` (GPU warm-up under a cover). Presets + lighting lift + Brightness + Interface size: DONE (sync-1008, `tests/next_perfctl`). Left: rendered / GPU measurement.
3. **Necromancer combat feel (DONE, `tests/next_feel`, `tests/next_combat_feel`, `tests/next_autocombat`).** Attack-target chase, hold / Shift, queued casts, cast gestures, hitstop, shake, Easy auto-combat, standing mouse-aim. Rune choices reach the caster and all 11 runes work; worn legendaries feed the legion (`tests/next_runes`).
4. **Difficulty, ascension, boons, omen, Altar actions (DONE, `tests/next_meta`).**
5. **Hero look (DONE, `tests/next_hero_look`):** worn gear, cape, pet, hero ring, legendary aura, replicated.
6. **Elite affixes (DONE, `tests/next_affixes`)**; only the target-frame chips are missing (gap 2).
7. **Gathering, professions, Depths, the three cathedral bosses (DONE: `tests/next_gathering`, `tests/next_depths`, `tests/next_bosses/*`, laborers + notices `tests/next_acre_guide`).**
8. **HUD feeds (DONE, `tests/next_hud_counsel`):** save chip, wave dial, loot / coin / shard / hurt sounds, Legion purchase, Depths readout, auto-combat button. The Next-step box is fed (`tests/next_acre_guide`).
9. **Boss meta-progression (DONE, `tests/next_boss_meta`):** Empowered summons, Covenant Seal, boss key prompt, prize claim, trophies, Chronicle, Codex, milestones, Nightfall. Limits: a client cannot call Empowered or see Nightfall's dim.
10. **Counsel and guidance state (DONE for counsel).** `counsel_busy` / `counsel_tick_ctx`, state-based tips, every panel pre-built and exercised. The Next box is fully fed (`tests/next_acre_guide`); chat stays solo.

Lower priority, listed in the body: the five non-necromancer disciplines, reconnect.



---

## 1. Combat and rites

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| 24 necromancer rites (needle, fan, rot lance, marrow spear, exhume, miasma, litany, corpse explosion, skull, step, frost, mantle, offering, cleave, veil step, rally, seed, siphon, prison, hands, storm + 4 signatures) | DONE | `game/dm_ability_system.gd`, `sim/sim_caster.gd` | `next/rites/rite_*.gd` (all 25 ids incl. `ossuary_wall`, `command_rend`, `dirge`, `plague_bloom`), `next/rites/README.md`; host-validated intents (D1) |
| Rite numbers, costs, cooldowns, essence, locks by level | DONE | `rules/combat/dm_abilities.gd` | same `DmAbilities` / `DmSimData`; `DmRiteCaster.request_cast` |
| Four disciplines' mods (Ossuary ward per thrall, Gravecaller champion/rend, Mourner corpse-heal, Rotweaver burst) | DONE | `data/content/disciplines.json`, `DmCharacterBuild` | `DmHeroBody.mods`, signatures per `next/rites/README.md` |
| Rune variants per rite (Hollow Choir, Requiem, Ossuary Ring, Impaling, Mass Grave, Colossus...) | DONE (`godot/next-runes`) | `rules/` runes, `DmCharacterBuild` | All 11 runes work on the rebuild: `rite_build()` carries the bag's sockets (next-feel) and the last four modules now honour theirs: Splinters (shard), Volley (3 needles), Creeping Rot (the circle walks, replicated), Contagion (stacks pass on death). Table-driven test over every rune id in the data, `tests/next_runes`. Left: a joined client's own sockets (the host only knows its own bag, D5) |
| Necromancer weapon line on the primary (staff reach + pierce, wand damage / cadence, sickle Withered, scythe arc + soul window) | DONE (`godot/next-combat-odds`) | `rules/combat/dm_weapon_line.gd`, `sim/sim_caster.gd _needle/_reap`, `dm_ability_system.gd` | `next/rites/rite_bone_needle.gd`: staff pierce (`needlePierce`, x`pierceDamageMult` into the enemy behind), sickle `needleWithered` on every needle, scythe `_reap` (100 deg arc, 3 hits + the boss with its own reach, +4 essence a hit, no crit, 520 ms swing), Splinters / Marrow-Tap on the scythe (Volley is the needle's), Splinters / Volley on the staff needle (volley needles pierce too), the reaped-kill soul window (`reaped_souls`, via `killer_paid(.., enemy)` -> `DmNextMeta`), the scythe's own gesture row (`DmRiteGestures.REAP_KEY`); fx shared in `DmRiteFx` (`pierce_*`, `reap_*`; the current client now calls them too). Wand / staff reach were already live through `DmWeaponLine` in `apply_cast_cost` / `shortfall`; `tests/next_combat_odds` C |
| Hotbar: keys 1-4, RMB (5), R signature (6), LMB primary, Grimoire loadout / loadout presets | DONE | `game/dm_loadout.gd`, `game_ui/dm_loadout_presets.gd` | `DmNextUiHost.rite_at/cast/set_rites` + `DmLoadout`; `next/rites/dm_rite_hotbar.gd` |
| Click an enemy = walk into range + primary attack (attack-target chase), hold LMB / Shift+LMB, held number keys | DONE (`27eba45e`, `tests/next_feel`, `tests/next_combat_feel`) | `game/dm_game_input.gd` `update_attack_target`, `tick_combat` | `DmNextInput.attack` + `next/feel/dm_combat_input.gd` (`DmCombatInput`): chase to the primary's range, sticky target, hold repeat at the rite's cooldown, Shift = cast in place, held keys 1-5 repeat after 150 ms; idle tick 0.4 us |
| Queued casts (cast fires when the previous cast finishes) | DONE (`27eba45e`) | `dm_game_input.gd tick_combat` | the caster stays a strict validator; `DmCombatInput` queues a deliberate cast refused `busy` (or `cooldown` with <= 220 ms left) for 220 ms and retries every 50 ms, other refusals drop it |
| Easy Auto Combat (G, owner-only gate) + auto-dodge | DONE (`godot/next-autocombat`) | `game/dm_auto_combat.gd`, `dm_auto_dodge.gd`, `dm_boss_telegraphs.gd` | `DmNextAutoCombat` (`next/feel/dm_next_auto.gd`) runs the old `DmAutoCombat` / `DmAutoDodge` / `DmBossTelegraphs` decision code; G / HUD button set `auto_combat`; `tests/next_autocombat` |
| Hero cast gesture / weapon clips per rite (`castClips.json`) | DONE (`27eba45e`) | `game/dm_avatar.gd cast()`, `dm_ability_system.gd` | `DmRiteCaster._gesture_cast` after each accepted cast, once per peer (own RPC, not an event), table `next/rites/dm_rite_gestures.gd` = the old `DmAbilitySystem._gesture` calls (kind, clip seconds, cast-flow, ability id for the weapon clip); 25 rows for 25 rites |
| Hitstop on heavy hits / elite deaths | DONE (`27eba45e`) | `game/dm_hitstop.gd` | `DmNextGame.hitstopper` (`DmHitStop`) fed by `enemy_fx.host.hitstop_cb` and `bosses.fx.host.hitstop_cb`; drives `Vfx.hitstop_scale` / `DmCreature.hitstop_scale` only (never `Engine.time_scale`, so the host sim and the wire are untouched, online-safe); off under `reduce_motion` |
| Camera shake on rites | DONE | `main/camera_rig.gd` | `caster.shake_requested.connect(camera.shake)` (`next/next_game.gd:324`, honours `reduce_motion`); rites emit it; boss / enemy fx shake via `host.camera`; hitstop separate. No dedicated assertion for rite shake (unverified in a test) |
| Hero hurt flash, floating damage/crit/DoT/thrall numbers (Settings: damage numbers) | DONE | `dm_event_fx.gd`, `dm_game_combat.gd` | `DmNextUiHost` (`hit_number`, `_on_hurt`, `watch_enemy`) |
| Cast feedback texts (essence/cooldown/locked) + `essence_short` counsel | DONE | `dm_game_input.gd feedback` | `DmNextUiHost._on_rejected` (rate-limited 600 ms) |
| Chill/root/stun/drag floats over hero, Bulwark/ward/barrier on hurt | PARTIAL | `dm_game_combat.gd on_hurt` | chill/root/stun/dragged floats + `_ward` in `DmHeroBody.take_damage`; Bulwark (knight family): N/A for now, no necromancer kit casts it (`DmPlayerRules` already cuts a frontal blow when `bulwarkUntil` is set, `tests/next_combat_odds` A), arrives with the non-necro disciplines (gap 10) |
| Other 5 disciplines (Hollow Knight, Grave Warden, Bell Monk, Carrion Witch, Veilwalker): kit rites (flail, toll, hook, crow, veil...) | MISSING | `data/content/abilities.json`, `kits.json`, `rules/` | `next/rites/dm_rite_registry.gd` is necromancer-only; a non-necro kit rite is refused `unavailable`. `DmHeroBody.family` exists. Owner priority: necromancer first, so low |
| Monk beat meter, Soul Harvest meter (souls), Bone Ward chip | PARTIAL | `dm_game_input.gd tick_chain_and_beat`, `dm_game_rewards.gd on_souls_charged` | Soul Harvest (own kills fill it; charged Marrow Spear / Miasma / Black Litany free and 1.5x) and the Bone Ward chip are on `next/meta/`; missing: monk beat meter (non-necro), wraith-nova on a charged cast, jade ring under the hero |
| Legendary gear mechanics (sync_legend: thrallDeathBurst, championEvery...) | DONE (`godot/next-runes`) | `dm_game_combat.gd sync_legend`, `DmLegend` | The caster resolves `DmLegend.sim_legend_of(mods)` once per build change and pushes it to `DmThrallHost.set_legend` (living thralls too); every legend mod in the data is implemented and tested: thrallDeathBurst, championEvery, spearRally, miasmaSpreadsWithered, witheredBurstAt, colossusGuard, wardReflect, litanyShatter, corpseWisp, wraithNova (`tests/next_runes`, worn through the real bag). Left: the Colossus Mantle hooks fire for the local hero only (host-authoritative hits on remote heroes use their default build) |
| Bonded Dead boon (thrall rises on area entry) | DONE (`godot/next-meta`, verified again on `godot/next-runes`) | `dm_game_combat.gd tick_bond` | `DmNextMeta._bonded_dead` (1.5 s after entering a hunting ground, necromancer, none standing, not the depths) calls `DmThrallHost.raise_bonded`; proven in `tests/next_meta` and, with a worn legend, in `tests/next_runes`. The row text above was stale |

## 2. Enemies

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| 27 enemy kinds (rat, hound, robber, ghoul, bat, moth, sac, wraith, golem, censer, penitent, templar, acolyte, deacon, seraph, gargoyle, flagellant, plague doctor, cinder husk, cinderhound, slag brute, pyre priest, mire leech, bog hag, fen wisp, drowned sexton, risen) | DONE | `sim/sim_enemy*.gd`, `game/dm_creature.gd` | `enemies/<id>.tscn` all 27 + `dm_enemy.gd`, `enemies/states/`, `enemies/kinds/` (state machines + NavigationAgent3D) |
| `niche` (boss add spawner) | N/A | `enemies.json` | handled as boss add spawn via director; no scene needed |
| Special AI (burrow/dig, flank, kite, unbind, sanctify, shield glance, censer pulse, hook, flask, scream, ember lob) | DONE | `sim/sim_enemy_ai.gd` | `enemies/kinds/*`, `enemies/states/*`; cues replicated by `next/next_net.gd` (`CUES`) |
| Bit-exact sim math / fdlibm determinism | N/A | `sim/fdlibm.gd`, `sim_exact.gd`, `game/dm_fdlibm_x.gd` | dropped: REBUILD "Enemies, AI, navigation: REFACTOR -> REBUILD ... drop bit-exact math"; D1 host-authoritative |
| Elite multipliers (hp/damage/scale, faster wind-up) | DONE | `sim/sim_data.gd ELITE` | `DmEnemy.elite` |
| Elite affixes (Bell-Tolled, Hungering, Shrouded, Vengeful) + affix rings/target-frame affix chips | DONE | `rules/combat/dm_affixes.gd`, `data/combat/affixes.json`, `game/dm_entity_views.gd` | Affixes, rings, motes and moments (`next/affixes`, `tests/next_affixes`) and the target-frame chips (`DmNextHudVm._affix_chips`, cached per target, same on a joined client: the meta comes from the replicated spawn data; `tests/next_brews_affix`) |
| Enemy level scaling by area/hero level, wave-tier hp/damage ramp, difficulty hp/damage multipliers | DONE | `sim_director.gd`, `DmEnemyStats` | `DmEnemyStats.area_level` / `ramp_tier` (`dm_wave_director.gd`); difficulty, Elder Dead, Iron Dead, wave-size / elite / deacon vows by `DmNextMeta` (`tests/next_meta`); Depths level `max(12, hero) + depth` (`tests/next_depths`) |
| Enemy hit/death/windup/voice sfx, telegraphs, hostile zones | DONE | `dm_event_fx*.gd` | `next/enemy_fx/` (`DmEnemyFx`, replicated once per peer) |
| Enemy idle fx (rising dust, hover motes, fen/fire per-kind idle) | DONE | `dm_entity_views.gd` | `DmEnemyFx` 5 Hz idle pass (dust, hover motes, tunnelling dirt, ember shedding, fen wisp, hag drips, sexton water) over watched enemies within 24x20 m (`next/enemy_fx/README.md`); all kinds have scenes; visual look not screenshot-verified here |
| Pooled creature bodies / shared materials | PARTIAL | `dm_entity_views.gd`, `dm_creature_mat.gd` | `director.warm(true)` preloads kinds; no body pool equivalent found; `DmCreature` / `dm_creature_mat.gd` reused |

## 3. Bosses

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Boss framework (brain, telegraph, phases 60/30 %, stagger, wipe reset, leash, view, fx, hp bar, minimap dot, boss music, E to summon) | DONE | `sim/boss_controller.gd`, `sim/bosses/*`, `game/dm_boss_view.gd` | `next/bosses/` (reuses the 7 `DmBossBrain`s on `DmBossNodeWorld`) |
| Gravedigger King (Hollow Graves) | DONE | `sim/bosses/` | `next/bosses/README.md` + `tests/next_bosses/run.gd` |
| Plague Saint (Cloister), Cinder Regent (Pyre), Mire Mother (Fen) | DONE | same | `tests/next_bosses/{saint,regent,mire}_run.gd` |
| Bone Abbess (Ossuary), Drowned Congregation (Nave), Bell-Sworn Prelate (Sanctum) | DONE | `sim/bosses/` | `next/bosses/` + `DmBossHost.LIVE` lists all seven; `tests/next_bosses/{abbess,congregation,prelate}_run.gd`; niches (`enemies/niche.tscn`), `cover()`, `echoes()` hooks done; areas are open on the rebuild |
| Boss rewards, first-kill trophy (+2 shards, rare relic), relic rune, reporter `boss` entry | DONE | `dm_game_rewards.gd on_boss_defeated` | `DmSessionRewards.on_boss_defeated`; `trophy_store` = `DmNextChronicle.claim_trophy` (backend `boss.<id>` counter, survives relaunch); `tests/next_boss_meta` (61 pass) |
| Empowered summons (Covenant Seal + gold), empowered prize claim, boss-busy refunds, boss key prompt | DONE | `dm_game_actions.gd call_empowered`, `dm_game_rewards.gd claim_empowered`, `game_ui/dm_boss_key_prompt.gd` | `next/bosses/dm_boss_meta.gd` (`call_empowered`, claim, refund, `boss_key_offer`); `DmNextUiHost.summon_boss(_empowered)`; `tests/next_boss_meta`. Limit: the Seal choice is the host hero's only (a joined client gets the plain summon) |
| Boss slow/root statuses, hitstop on boss hits | DONE | `dm_boss_view.gd`, `sim/bosses/boss_brain.gd` | Hitstop on boss hits DONE (`bosses.fx.host.hitstop_cb`, `tests/next_combat_feel`). The current client's boss controller has no slow / root at all (bosses are immune; only a stun staggers, capped); the rebuild's brain ignores them the same way, and a test now pins it (`tests/next_combat_odds` B: slow / ward_slow / root / chill land and show on the boss but its walk is unchanged; stun capped 0.5 s) |
| Boss spawn hint prompts / altar clicks | DONE | `dm_game_actions.gd interact` | `DmChapterhouse.interacted` -> `bosses.request_summon`, E key |

## 4. Thralls and corpses

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Corpse field (lifetime 26 s, cap 45, echo, toxic rupture, atomic consume, wisps, burst) | DONE | `sim/sim_corpse.gd`, `dm_event_fx*.gd` | `next/corpses/dm_corpse_field.gd` |
| Thralls: 8 kinds (warrior, shieldbearer, hound, wraith, archer, bone mage, plague bearer, colossus), follow/formation, cap, make-room, decay, rally, rend, sacrifice, plague burst | DONE | `sim/sim_thrall*.gd`, `game/dm_entity_views.gd` | `next/thralls/` (`DmThrall`, `DmThrallHost`, 15 Hz replication) |
| Enemies target thralls (weights) | DONE | `sim_enemy_ai.gd pick_target` | `dm_target_weight()` in `DmThrall` |
| Legion tier purchase (Legion panel Y), Legion gear kit (thrall weapons/armour) visuals | DONE | `game_ui/dm_legion_text.gd`, `ui/panels_a/dm_legion_view.gd`, `game/dm_gear_props.gd` | `DmNextUiHost.buy_legion` -> backend `necro_purchase`, tier raises thrall hp / damage, standing thralls bumped, purse adopted (`tests/next_hud_counsel`); thrall gear props reused from `DmEntityViews` |
| Corpse-eating enemy AI (deacon/hungering) | DONE | `sim_enemy_ai.gd` | Deacon `raised` supported; Hungering affix consumes corpses atomically via `DmCorpseField.consume` (`next/affixes`, `tests/next_affixes`) |
| Thrall hurt/crumble sounds | DONE | `dm_event_fx.gd` | `dm_thrall.gd` `thrallRise/thrallDeath` |

## 5. Statuses

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| slow, chill, root, stun, silence, bleed, withered, fracture, hex, sanctified, incensed, frenzy, shrouded, barrier | DONE | `sim/sim_*`, `DmEntityViews` motes | `next/status/dm_status_set.gd` (replicated 4 B/status, visuals via Vfx) |
| Player-side Bone Ward / Colossus guard as timed statuses; shrouded suspension in own Miasma | PARTIAL | `DmPlayerRules`, `dm_game_combat.gd on_hurt` | Bone Ward / Colossus guard: DONE as the current client has them: computed from the living thralls at the moment of each hit, never timed statuses (`DmHeroBody._ward`, `tests/next_combat_odds` A, `tests/next_runes` C). Still missing: shrouded suspension in own Miasma (`next/status/README.md` "Gaps") |
| Brews: damage, haste, ward, speed, essence | DONE | `rules/.../dm_brews.gd` | `DmNextBelt` via `p["brews"]` |
| Brews: lifesteal, fortune, wisdom | DONE | `dm_brews.gd` | Wisdom / fortune: `DmRewardsMember.sync_brews()` before each kill reward (per member, from its body's `p["brews"]`). Lifesteal: `DmSessionRewards._lifesteal` on the `damaged` signal when `from` is a `DmHeroBody` (host only), `DmBrews.lifesteal_heal`, hits summed per frame and healed once (target cap + one per-cast cap, as the current game), DoT ticks excluded, heals under 1 hp dropped. `tests/next_brews_affix` |

## 6. Areas and travel

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| 12 walkable areas built (Chapterhouse, Acre, Graves, Ossuary, Nave, Sanctum, Cloister, Pyre, Wing, Warren, Coliseum, Fen), streaming, fog, lighting, navmesh per area/door | DONE | `world/world_builder.gd` | `next/next_world.gd` (same builder), `areas/README.md` |
| Seals / doors / gates, kill-based unlocks (Warren 150 Graves kills, Swift Seals) | DONE | `dm_game_rewards.gd check_unlocks` | `DmChapterhouse.check_seals/apply_seals` |
| Waystone travel, T recall, minimap click travel, Waystone map panel (M); GM rule (dev-access characters see / use every non-instance area with a waystone, sync-1008: the shared panel reads `DmNextUiHost.dev_access`, `travel` uses `DmProgression.is_unlocked`, `tests/next_areas`) | DONE | `dm_game_actions.gd travel/start_recall` | `DmChapterhouse.travel/start_recall`, `DmNextUiHost.navigate`; host-only teleport (README gap) |
| Entry banners, first-entry Codex area discovery, first-entry counsel | DONE | `dm_game.gd _enter_area` | `next/areas/dm_area_flow.gd` |
| Omen sky tint + fog in hunting grounds | N/A | `dm_game.gd _omen_light` | the current client never calls `_omen_light` either (dead code); the Omen's numbers and chip are on `next/meta/` |
| Nightfall light dimming, wave-milestone banners (Elite Vanguard, Restless Crypts, Nightfall) | DONE | `dm_game_rewards.gd tick_milestones` | `next/areas/dm_wave_milestones.gd` (Elite Vanguard 3, Restless Crypts 6, Nightfall 8: banners, eased light, director variants); `tests/next_boss_meta`. Limit: a joined client does not dim |
| Multi-area simultaneous waves for party members in different areas | PARTIAL | n/a (co-op shared sim) | one director = one area (`areas/README.md`); D5 solo first |
| Occlusion dither shaders on walls/props | DONE | `world/dm_occ_*.gdshader` | same builder |
| Catacomb Warren stair -> Depths | DONE | `dm_depths_controller.gd` | Warren stair -> Depths: `DmDepths.stair_clicked` / `enter`; `tests/next_depths` |

## 7. Waves, Surges, Processions

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Area rosters, caps (GLOBAL_ENEMY_CAP 72), pacing, first wave 1.3x, elite bonus, packs, metas; waves spawn 18-30 m from the hero, outside the 15 m aggro (owner 2026-10-07, sync-1008, `tests/next_spawn_aggro`; rebuild only: the current client keeps its old ring) | DONE | `sim/sim_director.gd` | `next/spawn/dm_wave_director.gd` |
| Processions (WAVE_THEMES, 30 % from wave 2) + banner | DONE | `sim_director.gd` | director `_roll_theme`, `DmAreaFlow` |
| Grave Surges (crypt, 3 waves, Surge Quelled reward) | DONE | `sim_director.gd`, `dm_game_rewards.gd on_surge_cleared` | `next/areas/dm_grave_surge.gd`, `DmSessionRewards.on_surge_cleared` |
| Wave Speed dial (active tier +/-), Wave upgrade tiers | DONE | `dm_game.gd dial_wave/set_wave_tier` | `DmNextUiHost.dial_wave(delta)` -> active tier -> `DmNextProgress.apply_progress`; tiers bought + applied; `tests/next_hud_counsel` |
| Waves climb from area breaches | N/A | `world.json breaches` | slice uses a ring 9-14 m around the hero snapped to navmesh (areas README); Godot-idiomatic rebuild |

## 8. Depths (Catacomb Depths)

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Per-run generated floors, stairs, chest, depth rewards, depth readout, stair prompt, deepest-floor resume | DONE | `game/dm_depths_controller.gd`, `sim/depths_floor.gd`, `sim_depths_rules.gd`, `game_ui/dm_depths_stair_prompt.gd` | `next/depths/` (`DmDepths`, `DmDepthsRun`, `DmDepthsGround`): generated floors, stair card via `DmNextUiHost.enter_depths`, chest, rewards, death rule, `vm["depth"]` readout, resume at deepest; `tests/next_depths`. Limit: solo only (`can_enter` refuses 2+ players) |
| Depth kills reported to ledger (`report_floor`) | DONE | `DmProgressSync.report_floor` | `psync.report_floor` on floor clear / chest on the solo path (`next/depths/README.md`); chronicle `peak.depth`, `depths.*` |

## 9. Gathering, professions, laborers, garden, contracts

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Acre / Wing gathering nodes (view, hover tips, work loop, tool in hand, gather sfx, charms, AFK gather) | DONE | `game/dm_game_gather.gd`, `dm_gather_loop.gd`, `dm_gather_session.gd`, `dm_skills.gd`, `dm_node_views.gd`, `audio/audio_gather_sfx.gd` | `next/gathering/` (`DmNextGather`): 64 nodes, hover card, work loop, gather sfx, charms, Auto, AFK via `DmNextUiHost.start_afk / stop_gathering / afk_*`; `tests/next_gathering`. Limit: clients cannot start gathering; AFK bests stored under the current game's key (`tests/next_polish`) |
| Grave Laborers (visible laborers, collect, full notices) | DONE | `game/dm_game_labor.gd`, `dm_laborer_views.gd` | `DmNextAcre` (`next/gathering/dm_next_acre.gd`) runs both unchanged: pooled laborers at their posts in the Acre only, hover card + click -> Laborers (H), arrival / "filled up" notices, collect credits the gold + chronicle (`tests/next_acre_guide`) |
| Garden (plant/harvest ready notices) | DONE | `dm_game_labor.gd` | ready / still-growing notices on arrival and every 60 s, plant / harvest results ("Harvested ...", chronicle, level banner) through `DmNextAcre` (`tests/next_acre_guide`) |
| Contracts panel | DONE | `dm_game_labor.gd refresh_contracts`, `dm_contracts_panel.gd` | `refresh_contracts` feeds the guidance summary; a delivery credits the order's gold (the server returns it, never writes it: the Godot panel used to drop it), counts in the chronicle, toasts (`tests/next_acre_guide`) |

## 10. Crafting, forge, reforge, salvage, alchemy

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Forge / Workbench (craft, reforge tab, salvage, reagent shelf, grinder range) | DONE | `ui/panels_b/dm_forge_panel.gd`, `dm_reforge_view.gd`, `dm_salvage_panel.gd`, `dm_reagent_shelf_panel.gd`; `game/dm_game.gd near_grinder` | stations emit `station_interact` and `DmNextUiHost.near_grinder` is wired; craft, salvage, shelf verified on the offline backend (`tests/next_hud_counsel`); all panels pre-built; the full reforge flow (quote, pick, pay, new roll) is verified in `tests/next_acre_guide` |
| Alchemist's Wing stations (cauldron, alembic, reagents), brews, meals | DONE | `dm_game_actions.gd` | brews/meals/flasks DONE (`DmNextBelt`, now raising `brew_drunk` / `meal_eaten`); the cauldron, alembic and reagent shelf are used in the Wing, open their panels and craft through the API (`tests/next_acre_guide`) |
| Gold sinks (reforge quotes, server-priced) via `spend_on_server` | DONE | `DmProgressSync.spend_on_server` | the Reforge panel now pays through `psync.spend_on_server` (it called the api directly, so the server's price was never taken from our gold and the next save handed it back); backend and local gold agree after a reforge (`tests/next_acre_guide`) |

## 11. Inventory, bag, vault, equipment, visuals, cosmetics

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Reliquary (bag 24, equip slots, item cards/tooltips, locks, sort/Drink/Eat double-click, compare) | DONE | `ui/panels/dm_reliquary_panel.gd`, `game_ui/dm_ui_inventory.gd`, `game/dm_inventory.gd` | same classes via `DmNextUiHost.inventory`; pre-built under loading cover |
| Vault (shared storage, Chapterhouse only) | DONE | `ui/panels_b/dm_vault_panel.gd` | Vault station -> panel; deposit verified through the API (`tests/next_hud_counsel`) |
| Character stats from worn gear / set bonuses / affixes | DONE | `rules/gear`, `DmCharacterBuild` | `DmNextGame.build_for` + `DmNextProgress.request_stats` |
| Worn gear visible on the hero (weapons, off-hand, helm, hide-helm setting, class gear props) | DONE | `game/dm_game.gd:414,534 avatar.set_equipment`, `dm_avatar.gd`, `dm_gear_props.gd` | `DmHeroLook` (`next/hero/`): `DmAvatar.set_equipment` from the equipped bag, hide-helm, replicated to every peer; `tests/next_hero_look` |
| Legendary aura on hero | DONE | `dm_avatar.gd _legendary_aura` | legendary set aura via `set_equipment` (`tests/next_hero_look`) |
| Capes and pets (cosmetics panel N, Character sheet "Pets" tab), pet companion view, remote players' capes | DONE | `game/dm_game.gd load_cosmetics/apply_cosmetics`, `dm_pet_view.gd`, `ui/panels_a/dm_cosmetics_view.gd` | `DmNextUiHost.load_cosmetics` -> `DmHeroLook.set_cosmetics`: `avatar.set_cape`, `DmPetView`, replicated (remote capes / pets too); `tests/next_hero_look`, `tests/next_hud_counsel` |
| Hero dressing (contact shadow, pale ring, discipline glow, reticle, soul halo, target ring) | DONE | `dm_game.gd _dress_hero` | `DmHeroLook` hero ring: contact shadow, pale ring, discipline glow, reticle, soul halo, hover ring (local hero only, as the current client). Gap: hover ring does not follow the attack / auto target |
| Loot on ground (pickup 1.3 m, 60 s expiry, never flies, rarity beams, auto-loot rules) | DONE | `loot_view/`, `dm_game_rewards.gd` | `DmSessionRewards` + `DmLootView`; `loot_view.rules` from Settings -> Loot |
| Loot pickup/drop sounds (coin, drop, rarity) | DONE | `dm_game_rewards.gd collected` | `DmNextUiHost` forwards `loot_view.dropped_sound`, coin / shard pickup, `play_loot` by rarity (`tests/next_hud_counsel` sound checks) |
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
| Vows' world effects (Dry Cellar flask ban, Swift Seals, sync_world_vows) | DONE | `dm_game.gd sync_world_vows` | all world vows (Elder Dead, Iron Dead, Swollen Waves, Deacon Host, Elite Surge, Thin Graves, Prelate Echo, Swift Seals) and self vows (Dry Cellar -> belt) via `DmNextMeta.sync` (`tests/next_meta`) |
| Ascension (Altar: ascend, swear vows, open keys; reward/difficulty scaling by rank) | DONE | `dm_game.gd do_ascend/do_swear/do_open`, `ui/panels_a/dm_ascension_panel.gd` | the panel's API calls land through `refresh_progress` -> `DmNextMeta.sync` (rank -> rewards, vows -> director / bosses / corpses); `do_ascend/do_swear/do_open` on `DmNextUiHost`; `tests/next_meta` |
| Omen (weekly modifier: reward/shard mult, wave size, elites, chip) | DONE | `dm_game.gd _omen_for`, HUD `omen` | `DmNextMeta.omen_for` (same rotation), wave size / elites / xp / gold / shard mults, HUD chip; the Tolling forces Bell-Tolled (`next/affixes`); `tests/next_meta` |
| Kill chain (tiers, bonus, break, HUD chain meter) | DONE | `dm_game_rewards.gd on_chain_tier`, `DmKillChain` | `DmRewardsMember.chain` pays; tier banner / sound / burst, break sound + float, reset on death, HUD meter (`DmNextMeta`) |
| Milestones (best chain, kills -> gold) | DONE | `check_milestones` | `DmNextProgress._check_milestones` (ground gold drop) |
| Trophies (first boss kill) | DONE | `claim_trophy` | first-kill trophy persisted as the backend `boss.<id>` counter (`DmNextChronicle.claim_trophy`); `tests/next_boss_meta` |
| Chronicle (life stats / records for the Codex "Chronicle" tab) | DONE | `dm_game.gd _tick_chronicle/flush_chronicle` | `next/progress/dm_next_chronicle.gd`: one Chronicle fed by kills, gold, gathering, Depths, deaths, boss counters, play time; flushed to the backend, Codex tab reads it (`flush_chronicle`); `tests/next_boss_meta` |
| Codex (kills discovered, areas) | DONE | `dm_game.gd codex_discover` | `next/progress/dm_next_codex.gd`: enemy kinds (first spawn within 40 m), bosses on waking, areas on entry; saved per character; `tests/next_boss_meta` |
| Leaderboard | MISSING | only `DmApi.get_leaderboard` (`net/dm_api.gd:506`); no panel in the current client either | only `DmApi.get_leaderboard`; no panel in the current client either; the public website shows it; no in-game UI planned |
| Gear Atlas panel (.), Class panel (change discipline) | DONE | `ui/panels_a/dm_atlas_panel.gd`, `dm_class_panel.gd` | Atlas reads data; Class panel -> `DmNextUiHost.class_changed` -> `world_restart` -> `main.gd _on_next_restart` re-enters with the new character; `tests/next_front` (class change check) |

## 14. NPCs, dialogue, counsel, onboarding

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Hub NPCs (spots, talk range, "!" news marker, first-sight), E to talk | DONE | `game/dm_npc_views.gd`, `dm_game.gd _tick_npcs` | `next/chapterhouse/dm_hub_npcs.gd`, `DmChapterhouse.talk_key` (acre / wing NPCs only appear in their areas) |
| Covenant dialogue / guidance memory / Next box | DONE | `ui/panels_a/dm_dialogue_panel.gd`, `game_ui/dm_game_ui.gd guidance_state` | `guidance_state` is fed the same facts as the current client plus the skills, trophies, labor and contracts that used to be stale; recomputed only on change (`hud/README.md`, `tests/next_acre_guide`) |
| Counsel tips (cadence, events, store, progressive HUD reveal, NEW cues) | DONE | `ui/onboarding/`, `game_ui/dm_hud_reveal.gd` | UI side reused; `counsel_busy` / `counsel_tick_ctx` = `DmNextCounsel`: state-based tips and in-combat suppression run; events from DmNextProgress/Areas/UiHost |
| First-hour guidance pings, `/party` etc. chat commands | PARTIAL | `game_ui/dm_chat_command.gd` | guidance minimap ping DONE (`vm["minimap"]["ping"]`, `guide_ping` honoured); `/party` makes a private session and prints its code, `/party <code>` joins by code, `/solo` `/leave` leave (`DmNextUiHost.party_*`, `tests/next_lobby`); `send_chat` = party chat in a party, "(solo) Nobody hears you" alone |

## 15. UI panels (one row per panel; all exist on the rebuild via `DmGameUi`, status = fed + reachable)

| Panel (key) | Status | Where | Rebuild note |
|---|---|---|---|
| Reliquary / bag (I, B) | DONE | `ui/panels/dm_reliquary_panel.gd` | pre-warmed, tested |
| Grimoire (L) + loadout presets + rune picks | DONE (`godot/next-runes`) | `ui/panels_a/dm_grimoire_*`, `game_ui/dm_loadout_presets.gd` | rune picks show, socket / swap / remove through the panel's own path and reach the caster at once (`tests/next_runes` B) |
| Settings (Esc) | DONE | `ui/panels/dm_settings_panel.gd` | pre-warmed; some keys inert (section 19) |
| Character sheet (J) stats tab | DONE | `ui/panels_a/dm_sheet_view.gd` | opens with the build's stats (tested) |
| Capes & Pets (N, sheet tab) | DONE | `dm_cosmetics_view.gd` | `DmNextUiHost.load_cosmetics` -> `DmHeroLook` (cape + pet appear, replicate) |
| Legion (Y) | DONE | `dm_legion_view.gd` | Reinforce buys a tier via the API; thrall hp / damage follow; standing thralls bumped |
| Forge / Workbench (C) incl. reforge, Salvage, Reagent shelf | DONE | `ui/panels_b/*` | craft / salvage verified via the API; reforge flow verified (`tests/next_acre_guide`) |
| Vault (V) | DONE | `dm_vault_panel.gd` | deposit verified via the API |
| Acre ledger: Professions (P), Garden (U), Labor (H), Contracts (O), Gather report | DONE | `dm_professions_panel.gd`, `dm_garden_panel.gd`, `dm_labor_panel.gd`, `dm_contracts_panel.gd`, `dm_gather_report_panel.gd`, `dm_acre_ledger.gd` | Professions (P) DONE; Garden (U), Labor (H), Contracts (O) work through the backend (`tests/next_hud_counsel`); visible laborers and the garden / contract notices are `DmNextAcre` (section 9) |
| Codex (K) | DONE | `dm_codex_panel.gd` | enemy kinds, bosses and areas discovered + saved; Chronicle tab fed (`flush_chronicle`); `tests/next_boss_meta` |
| Gear Atlas (.) | DONE | `dm_atlas_panel.gd` | data-only |
| Waystone map (M) | DONE | `dm_waystone_panel.gd` | via `travel` |
| Ascension / Altar | DONE | `dm_ascension_panel.gd` | boon purchase verified via the API |
| Class panel | DONE | `dm_class_panel.gd` | `class_changed` implemented (`next/hud/dm_next_ui_host.gd:403`); `tests/next_front` |
| Dialogue | DONE | `dm_dialogue_panel.gd` | NPC hub |
| Boss key prompt (Empowered choice) | DONE | `game_ui/dm_boss_key_prompt.gd` | `boss_key_offer` -> prompt -> `summon_boss` / `summon_boss_empowered`; `tests/next_boss_meta` |
| Depths stair prompt | DONE | `game_ui/dm_depths_stair_prompt.gd` | `depths_stair_offer` -> existing card -> `enter_depths`; `tests/next_depths` |
| Belt picker (Z/X slot) | DONE | `game_ui/dm_belt_picker.gd` | `DmNextBelt.load_pick/set_belt` |
| Bug report | DONE | `game_ui/dm_bug_report_view.gd` | uses `ui.game.api.send_bug_report`; verified end to end on the offline backend (`tests/next_acre_guide`) |
| Chat line / chat box | PARTIAL | `game_ui/dm_chat_command.gd` | local only |
| Spell tooltip, item tooltip, stat key | DONE | `game_ui/dm_spell_tooltip.gd`, `ui/widgets/dm_item_tooltip.gd` | |
| Keybind rebinding (loadout hotkeys) | DONE | `game_ui/dm_ui_binds.gd` | `DmGameUi._unhandled_key_input`; `DmKeybinds` (game) not used by rebuild: input actions registered at runtime by `DmNextInput` |

## 16. HUD widgets

| Widget | Status | Rebuild note |
|---|---|---|
| Health / resource orbs, level badge, XP bar | DONE | `DmNextHudVm` |
| Hotbar + cooldown sweep, primary socket, rune icon, locked/affordable | DONE | slots from `DmAbilities` |
| Belt chips (Q/Z/X), brew timers | DONE | `DmNextBelt.rows()` |
| Target frame (name, hp, statuses, elite affix chips) | DONE | `DmNextHudVm._target` / `_affix_chips` |
| Boss bar (phases ticks 60/30 %) | DONE | `vm["boss"]` |
| Party frames | DONE | roster-driven; a joiner's HUD has them too (level shows 1 for remote players on a joiner's screen: the roster carries no level yet) |
| Minimap (enemies, thralls, corpses, doors, boss dot, click travel) | DONE | `DmHudMinimap` |
| Area label + progress | DONE | label + progress; Depths readout (`vm["depth"]`) |
| Upgrade box (Empower/Quicken, dial) | DONE | tiers + dial (`dial_wave`) |
| Thrall pips / legion chip | DONE | |
| Soul Harvest meter | DONE | `next/meta/` |
| Kill chain meter | DONE | `next/meta/` |
| Omen chip | DONE | `next/meta/` |
| Depth readout | DONE | `vm["depth"]` = `DmDepths.hud_state()` |
| Bone Ward chip | DONE | `next/hud/dm_next_hud_vm.gd` |
| Auto-combat button | DONE (G / the HUD button set `auto_combat`; `DmNextAutoCombat` runs it) | |
| Next-step box, guidance ping, progressive reveal / NEW pips | DONE | Next box + minimap ping DONE (`tests/next_acre_guide`); reveal + NEW pips verified on the rebuild (`tests/next_polish` B: a fresh character holds shards / skills / dial back, progress reveals them with a NEW pip, opening the panel clears it) |
| Toasts, banners, loot toast, floating numbers, death wash, hit flash | DONE | |
| Save-state chip (`save` text/warn) | DONE | `DmNextUiHost.save_chip()` (psync + bag state) |
| Node/laborer hover tip | DONE | `DmNextGather` hover ring + node card (`tests/next_gathering`); laborer hover card + click on `DmNextAcre` (`tests/next_acre_guide`) |
| Interaction prompt + hover highlight | DONE | `DmChapterhouse` |

## 17. Settings keys (`game/dm_settings.gd`)

| Key | Status | Note |
|---|---|---|
| `vol_master/combat/amb/music/ui` | DONE | `AudioDirector.apply_settings` |
| `loot_<tier>` (5) | DONE | `loot_view.rules` |
| `damage_numbers` | DONE | `DmNextUiHost.float_text` |
| `reduce_motion` | DONE | Vfx + camera |
| `graphics` (low / medium / high / ultra) | DONE (sync-1008) | `DmNextPerf.apply` reads the shared `DmGraphicsPreset` table: moon shadows + reach / atlas / splits / soft filter, bloom, prop lights, prop shadow range, MSAA / aniso / LOD, `vfx.quality` + Binbun, governor floor, per-preset brightness `lift`; live on Settings change (`tests/next_perfctl`) |
| `brightness` (80-130%) | DONE (sync-1008) | exposure multiplier on `DmWorldBuilder` (`set_brightness`), applied by `DmNextPerf.apply`; clamp / persistence in the shared `DmSettings` (`tests/game/graphics_run`, `tests/next_perfctl`) |
| `ui_scale` (Interface size 80-125%) | DONE (sync-1008) | window `content_scale_factor` set by `DmNextPerf.apply` on top of the project's canvas_items stretch (1600x900 base); HUD column clamps / ultrawide frame are in the shared `DmHud` (`tests/next_perfctl` checks the factor; the HUD layout itself is the current client's tests, not re-run against the rebuild's rendered HUD) |
| `fps` (Engine.max_fps), `auto_res` (resolution governor) | DONE | `DmNextPerf` (`next/perf/`), same `DmResolutionGovernor` constants; `graphics_chosen` is handled inside the shared `DmSettings` |
| `difficulty` | DONE | `DmNextMeta.set_difficulty` (director, rewards, bosses) |
| `auto_combat` / `auto_gather` | DONE | `auto_combat` by `DmNextAutoCombat`; `auto_gather` read by `DmNextGather` (`autoEnabled`) |
| `hide_helm` | DONE | `avatar.settings = ui_host.settings` (`next/hero/dm_hero_body.gd:152`), `DmAvatar.refresh_all` on a Settings change |
| `no_tips`, `guidance`, `guide_ping` | DONE | consumed by `DmGameUi` counsel; `counsel_busy` / `counsel_tick_ctx` = `DmNextCounsel` (`tests/next_hud_counsel`) |
| `dev_access` | DONE | `DmNextUiHost._apply_dev_access` / `_push_dev_access`: gated like `DmGame` (dev account = `gm_enabled` or token user `brbmuffins`, never an offline profile; `dev_access = dev_account and settings.dev_access`); effects: progression (sealed halls open, kills banked), gathering tiers, the host's own caster (`DmRiteCaster.dev`, locked rites cast), gates via `apply_seals`, toast. `tests/next_polish` |
| Settings -> Leave / log out | DONE | `leave_world` -> `left_world` -> `main.gd _on_next_left` (save, free, login screen); `tests/next_front` log-out checks |

## 18. Audio

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Music director (area cues, boss score, crossfades), zone ambience beds, accents | DONE | `audio/`, `main/audio_hooks.gd` | `DmAudioHooks` on `DmNextGame` (same autoload); every area has cue + bed (tested) |
| Footsteps by surface, wading | DONE | `audio_footsteps.gd` | `DmAudioHooks._footsteps` |
| Boss war-drum bed, boss music | DONE | `AudioDirector.set_boss_music` | `next/bosses/` |
| Enemy windup/strike/death/voice sfx | DONE | `dm_event_fx.gd` | `DmEnemyFx` |
| Rite sfx (needle, loops: miasma/siphon) | DONE (`tests/next_combat_odds` D) | `dm_ability_system.gd`, `dm_rite_fx.gd` | Table-driven over all 25 rites: the same cast on the current `DmAbilitySystem` and on the rebuild's `DmRiteCaster` with recording audio back-ends; the rebuild plays every sound / loop the current client does (needleCast / needleHit, miasma + miasmaLoop, siphon + siphonLoop, boneStormLoop, handsLoop, dirgeLoop, bloomPulse, sigWall / sigRend ...); only scenario-dependent hit sounds (boneHit, tollSmall ...) may differ. The scythe swing's `spear` / `boneHit` are `DmRiteFx.reap_swing` |
| Thrall rise/death, level-up, UI/panel sounds | DONE | | `dm_thrall.gd`, `DmNextProgress`, `DmGameUi.sound` |
| Loot, coin, rarity sounds; hero hurt sound; gather sfx family | DONE | `audio_gather_sfx.gd`, `collected()` | loot / coin / shard / hurt / lowHealth forwarded (`DmNextUiHost`, `tests/next_hud_counsel`); gather sfx (`click`, `error`, `reel`, `skillUp`) in `DmNextGather` |
| Co-op `partner` audio flag | N/A | `AudioDirector.partner` | D3 session model |

## 19. VFX

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Vfx autoload (Binbun effects, decals, beams, motifs, danger), `SPELL_FX` rite looks | DONE | `fx/` | reused unchanged (REBUILD "Assets rule"); `DmRiteFx` |
| Enemy telegraphs/strikes/deaths, hostile zones, boss telegraphs | DONE | `dm_event_fx*.gd` | `DmEnemyFx`, `DmBossFx` |
| Corpse wisps, rise/fall, status motes | DONE | | `next/corpses`, `next/status` |
| Hero ring / halo / reticle / target ring | DONE | `_dress_hero` | `DmHeroLook` (see Inventory) |
| Waystone ring/glow/portal/motes | DONE | `_dress_waystones` | `DmChapterhouse._dress_waystones` |
| Click-move marker | DONE | | `DmNextInput.click_move` |
| Omen sky tint, nightfall dimming | DONE | Nightfall dimming = `dm_wave_milestones.gd`; the Omen sky tint is N/A (the current client never calls `_omen_light`) |
| Hitstop | DONE | `DmNextGame.hitstopper` (see Combat) |
| Graphics-quality scaling of effects (Low / Medium / High / Ultra; Medium has no Binbun layer) | DONE (sync-1008) | `DmNextPerf.apply`: Low = no moon shadows / bloom, fewer prop lights, halved weather, `vfx.quality` |

## 20. Saves, accounts, front screens, launcher

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Login, register, resume token, claim_session | DONE | `front/dm_front_flow.gd`, `dm_login_screen.gd` | `main.gd`: `-- --next` goes through `DmFrontFlow` (login / register / resume) into `_enter_next`; `-- --next --class=N` still skips it; `tests/next_front` |
| Character select / discipline card (create character) | DONE | `front/dm_char_select_screen.gd` | `dm_char_select_screen.gd` -> `DmNextGame` with that discipline (all four necromancer disciplines walked); `tests/next_front` |
| Online mode (`--online`) with VPS backend | DONE solo (`tests/online_live`, opt-in) | `main.gd`, `next/rewards/dm_session_rewards.gd` | verified against the live backend with the QA account: login, existing character (D8), area entry, kills, server-rolled gear, gold / xp / bag saves, a `spend_on_server` reforge, session end, relog. The live server has no `/api/sessions` (migration 041 not applied): `DmSessionRewards.legacy_ledger` credits kills through `/api/kills/report` instead. Open: backend ER_DATA_OUT_OF_RANGE on kill reports for fresh characters, `roll-gear` pool deadlock (see `next/rewards/README.md`) |
| Online staff gate (D10: after sign-in the manifest's `online` block + `GET /api/me` staff flag decide; others see 'Online opens soon'; fails closed; live since 2026-10-07 with launcher 0.6.1) | DONE (sync-1008: one implementation, `front/dm_online_gate.gd` + `DmFrontFlow`, both clients; `tests/next_online_gate`) | `front/dm_online_gate.gd`, `main.gd` | the rebuild enters through the same `DmFrontFlow` |
| Offline edition (local backend `DmMockBackend`, separate characters) | DONE | `game/dm_offline.gd`, `net/dm_mock_backend.gd` | D4; `DmNextGame` takes `DmOffline.make_api` |
| Cloud saves: progress, necro, inventory | DONE | `DmProgressSync`, `DmInventory` | reused |
| Class change (rebuild world with new discipline) | DONE | `dm_game.gd class_changed` | `class_changed` -> `world_restart`; `tests/next_front` |
| Log out | DONE | `dm_game.gd leave_world` | `leave_world` -> `_on_next_left(true)`; `tests/next_front` |
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
| Lobby UI (find/create/join, private codes, public list, kick, open/closed, every error in words) | DONE | `/party` chat commands + party code | `ui/panels/dm_lobby_panel.gd` (Party window: key F, HUD button, Settings' Play together, `/party`), `game_ui/dm_ui_lobby.gd`, `next/party/dm_next_party.gd`; hosting turns the running solo session into a hosted one (`DmSession.swap_transport`), joining swaps the solo game for a client game (`main.gd`); `tests/next_lobby` (in-process, UI, multi-process over the real relay) |
| Joiner gets a real HUD, real character handshake, own backend api for loot/XP | DONE (core) | | the joiner runs `DmNextUiHost` / `DmGameUi`, a `DmNextJoiner` (own `DmProgression` + `DmProgressSync`, backend `session_join` + heartbeat with its OWN token, loot view, bag, gear rolled by ITS api); the host sends it the accepted XP / kills and its drops. Left: its gear / upgrades / level-ups do not feed the host's sim for its body (default build at its reported level), flasks and brews are host-only, first-kill trophies are not paid to joiners, a session on a backend without `/api/sessions` credits nobody but the host |
| Remote players' gear/cape/pet display, party chat | DONE | `dm_game_coop.gd dress_remote/chat_line` | remote players' gear / cape / pet (`DmHeroLook`, `tests/next_hero_look`); party chat: Enter, `[name] text`, 4 lines/s per sender (`DmNextParty`) |
| Reconnect / rejoin (10-minute window; D13 2026-10-07 reverses 'not planned': disconnects get a rejoin window) | MISSING (decided, not built) | `net/realtime/dm_rt_reconnector.gd`, `dm_rt_rejoin_store.gd` | D6: no migration; a drop leaves both sides clean (client back to its own hub, host plays on solo), reconnect is a later track |
| Session `session_open/report/end`, heartbeats | DONE | `net/dm_api.gd` | `DmSessionRewards` |

## 22. Bug report button and daily agent

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| HUD "Report a bug" button + Settings -> Report a bug form (`/api/bug-reports`) | DONE | `game_ui/dm_bug_report_view.gd`, `ui/hud/dm_hud.gd` | opens inside Settings, sends through `api.send_bug_report` (the test uses the OFFLINE backend only), the report lists back; the context's `release` is now `godot-next-<version>` (was "slice") (`tests/next_acre_guide`) |
| Daily Claude triage agent, Discord "fixed - live now" alerts | N/A | server side | unaffected (backend/server) |

## 23. Perf features

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Load-time warm-up (models, Binbun effects, shaders, pooled bodies) | DONE | `game/dm_warmup.gd` | `DmNextWarmup` (`next/perf/`): every enemy/thrall/boss body (opaque, fade, elite, spectral), every Binbun effect, decal layers, telegraphs, and the 13-area tour incl. the no-omni-light and flash-light variants, under `DmWarmup`'s cover (no pooled bodies: enemies are scenes) |
| Loading screen with progress | DONE | `game/dm_warmup.gd` under cover, `main.gd` | `main.gd _enter_next` shows the key-art `DmLoadingScreen` ("Waking the dead...") from the world build; `DmNextWarmup` draws its own progress cover; dismissed after `start()`; `tests/next_front`, `tests/next_perfctl` |
| Resolution governor (auto-res, min 0.6) | DONE | `game/dm_resolution_governor.gd`, `dm_game.gd _apply_render_scale` | `DmNextPerf.pace` (same constants; held on every area entry); per-preset floor (Low 0.6, others 0.85) via `set_floor` (sync-1008) |
| FPS cap / graphics high-low | DONE | `_apply_graphics` | `DmNextPerf.apply`; Medium / Ultra presets (sync-1008) |
| Effect/pool budgets (Vfx pools, decal layers), per-frame cost discipline | DONE | `fx/` | reused; per-track perf budgets in `tests/next*` |
| Event-driven / throttled systems (corpse expiry, 10 Hz hub tick, 20 Hz net only with peers) | DONE (new) | | the rebuild's stated perf rule |
| Navmesh-based enemies (replaces custom nav) | DONE (new) | `sim/nav.gd` | `next/next_world.gd` ~130 ms bake |

## 24. Anything else

| Feature | Status | Current | Rebuild / note |
|---|---|---|---|
| Hero death -> respawn in Chapterhouse (4 s), death veil | DONE | `dm_game.gd respawn` | `DmHeroBody.RESPAWN_S` |
| Bone Grinder, Lectern, Sawpit, Kiln, Fire stations | DONE | `dm_game_actions.gd interact` | each used in the Acre like a click: panel opens, first-use counsel event, craft / salvage through the API (`tests/next_acre_guide`) |
| Boss summon in-world prompts, Next-step guidance ping | DONE | boss summon in-world prompt DONE (E + click prompts, boss key prompt); the Next box + minimap ping are fed the full state (`tests/next_acre_guide`) |
| Dev tools (F9 break seals, `__cwDebug`, QA driver) | DONE | `main/qa_driver.gd` | QA driver (`-- --qa`) now drives the rebuild (`_process_next`: pack of the dead, rites cast, screenshots; `tests/next_polish`). F9 break seals is new on the rebuild (the current Godot game has none; gated by `dev_access`, `DmNextUiHost.dev_break_seals`). `__cwDebug` is the web client's console hook: N/A in Godot |
| Tests: rules suites, session/relay/rites/status/corpses/thralls/areas/bosses/hud/progress | DONE | `tests/` | `tools/godot/run-all-tests.sh` |
| Mobile build / web build | N/A | | D9 web retirement; mobile not in Godot scope |
