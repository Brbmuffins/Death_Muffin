# Covenant counsel (godot/ui/onboarding)

Faithful port of `src/ui/Onboarding.ts` (queue, persistence, card, TIP_ANCHOR glow) and `src/ui/counselCadence.ts` (calm/ASKED/DANGER/HERE/GROUPS rules).
Tip text, kinds, groups, priorities, places and anchors are NOT retyped: `tools/godot/fixtures-onboarding.ts` exports them from the real TS to `godot/data/onboarding/tips.json` (120 tips).

| file | web source |
|---|---|
| `dm_counsel_data.gd` (`DmCounselData`) | `TIPS`, `TIP_ANCHOR`, `renderText`, `kindOf/groupOf/priorityOf` |
| `dm_counsel_cadence.gd` (`DmCounselCadence`) | `counselCadence.ts`: canShow, pickNext, prune, shouldPreempt, shouldYield, showMs |
| `dm_counsel.gd` (`DmCounsel`) | class `Onboarding` (show, pump, sendBack, present, dismiss, reset, clear, hover pause) |
| `dm_counsel_events.gd` (`DmCounselEvents`) | every `onboarding.show()` / `host.tip()` call in WorldScene.ts / DepthsController.ts |
| `dm_counsel_store.gd` (`DmCounselStore`) | localStorage (`dm_tips_v1_<char>`, `dm_counsel_position_v1`) |
| `dm_counsel_view.gd` (`DmCounselView`) | `present()`/`place()` + `.dm-tip-glow`, uses `DmTipCard` and `DmHud.tip_anchor_rect/tip_default_position` |

## Wiring (integrator)
```gdscript
var store := DmCounselStore.new("user://dm_counsel.json")
var counsel := DmCounsel.new(character_id, store)            # own ms clock, advanced by tick()
counsel.stale = func(id): return id == "thrall" and no_thrall_alive()          # WorldScene.ts:1420
counsel.key_for = func(ability): return str(loadout.find(ability) + 1) if ability in loadout else ""
counsel.auto_allowed = owner_flag                            # settings.gateAuto
counsel.tips_enabled = not settings.no_tips
var view := DmCounselView.new(); view.setup(counsel, hud, store); hud_layer.add_child(view)
# every frame (WorldScene.counselBusy):  busy = {combat, hurt, talking, banner, dead, panel, area, safe}
counsel.tick(delta, busy)
counsel.notify("enemy_spawned", {"def": def, "elite": elite, "near": dist < 40, "area_safe": area_safe})
counsel.notify_tick(ctx)            # every 400 ms, WorldScene.tickOnboarding (ctx documented on DmCounselEvents.tick_calls)
# Settings: Don't show tips (card button) -> counsel.tips_disabled signal: store Settings no_tips = true
#           Settings no_tips toggled -> counsel.set_tips_enabled(not no_tips)
#           Settings "Show tips again" (settings panel action reset_tips) -> counsel.show_tips_again({atlas_revealed, spells_revealed}) + hud.toast("Covenant counsel will guide you again", "good")
# audio: connect counsel.card_shown for the counsel-card cue (audioMap.ts site "Onboarding.ts show()")
```
`busy` semantics (WorldScene.counselBusy): combat = enemies near or hit within 4 s; hurt = hit within 4 s or boss awake; talking = dialogue open; banner = `hud.banner_active()`;
dead; panel = a DmWindow open and no dialogue; area = current area id; safe = AREAS[area].safe. `lastCombatAt/lastHurtAt` bookkeeping (WorldScene.ts:3735, 3755, 4500) stays in the scene.
Pause the game -> stop calling tick: counsel time pauses with it.

## Event ids -> web source
`notify(event_id, ctx)`; ctx keys in the comments of `dm_counsel_events.gd`. Format: tip @web line (file WorldScene.ts unless noted).

| event id | calls (tip @line) | ctx / note |
|---|---|---|
| `rite_primary_set` | rite_tip @552 | ctx {ability}: LMB socket changed (first time each level-gated rite is placed) |
| `rite_key_set` | rite_tip @602 | ctx {ability}: a rite placed on a key |
| `grimoire_opened` | grimoire @571,1828; runeHunt @577 | ctx {family, owns_rune: bool (bag or socketed)} |
| `rune_socketed` | runeSocketed @1047 |  |
| `necro_weapon_changed` | necroWeapon @1085 | ctx {main, was_main}: worn weapon line changed (not a staff) |
| `set_bonus_gained` | setBonus @1097 |  |
| `loadout_check` | loadouts @1036 | ctx {family, learned_rites, rune_count} |
| `world_entered` | welcome @881; knight_rage @883; warden_oil @884; monk_beat @885; witch_offal @886; veil_forms @887; signature @888; grimoire @889 | ctx {family, level, grimoire_unlocked} |
| `level_up` | signature @4427; grimoire @4437; loadouts @1036 | ctx {level, grimoire_unlocked, family, learned_rites, rune_count} |
| `bag_changed` | bag_filling @938; legion @940; rune @942; loadouts @1036 | ctx {slots_used, bag_size, family, kit_candidates: bool, owns_rune: bool, learned_rites, rune_count} |
| `gear_equipped` | gearEquip @1235 |  |
| `tool_belted` | toolBelt @1237 |  |
| `stat_sheet_opened` | statSheet @1238 |  |
| `reforge_done` | reforge @1284 |  |
| `vault_opened` | vault @1306 |  |
| `salvage_opened` | salvage @1307 |  |
| `salvaged` | salvage @1686 |  |
| `class_panel_opened` | change_class @1330 |  |
| `bag_full` | bag_full @782 | gathering stopped: bagFull |
| `collected` | relic @4165; atlas @4168; legendary @4172; armor @4173; reagent @4174; affix @4175 | ctx {gear, legendary, armor, reagent, affixed: bool} (any item in the pickup matches) |
| `laborers_seen` | laborers_working @670 |  |
| `gather_started` | gather @2087,2088 | ctx {rich} |
| `skill_up` | skill_up @3236 |  |
| `station_opened` | station @2477 |  |
| `cauldron_opened` | wing @2484 |  |
| `reagent_shelf_opened` | wing @2490 |  |
| `lectern_used` | codex @2508 |  |
| `meal_eaten` | meal @2249 |  |
| `brew_drunk` | brew @2263 |  |
| `npc_first_sight` | people @1609 |  |
| `minimap_travel` | minimap @2063 |  |
| `area_first_entered` | cloister @5557; pyre @5558; fen @5559; warren @5560; wing @5561; coliseum @5562; acre @5580 | ctx {area}: the first time the hero enters it this session (WorldScene announcedAreas) |
| `omen_told` | omen @5578 |  |
| `auto_combat_cast` | auto_combat @2202 |  |
| `essence_short` | essence @2216 |  |
| `enemy_spawned` | deacon @3682; first_sight @3684; elite @3685; move @3687 | ctx {def, elite, near: within 40 m (default true), area_safe} |
| `corpse_near` | exhume @3692 | ctx {area_safe, dist} |
| `sanctify_near` | sanctify @3616 | ctx {dist} |
| `surge_opened` | surge @4074 | only when the surge is in the hero's own area |
| `chain_started` | chain @4224 |  |
| `souls_charged` | souls @4407 |  |
| `hurt_check` | hurt @4497 | ctx {hp, max_hp} |
| `can_ascend` | ascend @5101 |  |
| `depths_solo` | depths_solo @224 (DepthsController.ts) |  |
| `depths_floor` | depths_floor @245 (DepthsController.ts) |  |
| `depths_affix` | depths_affix @304 (DepthsController.ts) | ctx {extras} |
| `depths_chest` | depths_chest @367 (DepthsController.ts) |  |
| `depths_stair_near` | depths @422 (DepthsController.ts) |  |
| `show_tips_again` | minimap @1320; belt @1321; atlas @1322; grimoire @1323; codex @1324 | ctx {atlas_revealed, spells_revealed} |
| `tick_calls` (`notify_tick`) | wave @3761; thrall @3764; litany @3776; burst @3777; codex @3778; tool @3779; belt @3781; prelate @3782; boss_<id> @3787; boss_seal @3788; altar_unlocks @3794; vows @3795; boons @3797; gate @3804 | WorldScene.tickOnboarding, ctx in `DmCounselEvents.tick_calls` |

`tests/onboarding` checks this table against every call found in the web source (`fixtures/callsites.json`), both directions (no web trigger missing, none invented).
The event is the web call site: the integrator fires it where the web scene fires `show` (some web conditions, e.g. "spawn within 40 m", "surge in own area",
"first time in area", "NPC within 14 m and first sight", "door within 6 m" are the caller's to evaluate or pass in ctx as noted).

## Behaviour notes
- One card at a time; calm cards wait for quiet (no fight, talk, banner, panel; 20 s after the last card; 3 s at session start), danger cards show in fights, asked cards promptly; 150 s subject groups (40 s for enemy/lesson); stale tips pruned; calm backlog capped at 4.
- Card yields to fights/talk/panels after 6 s, is preempted by Hurt? / fight lessons after 5 s, leaves with the hero for place tips, and returns to the queue front (marked unseen) when it yields.
- Card: 25-40 s (fight cards 14 s+), timer pauses on hover/drag, click dismisses, header drags (position saved, clamped 8 px in), hidden under banners/panels per ui.css, fade in/out.
- Glow: 2 px #e2c98f outline at 3 px offset with pulsing halo (1.4 s), `reduce_motion` flag holds it steady. Anchors alias like the web selectors: brew->belt, bag_full/bag_filling->relic, skill_up->gather.

## Placeholders vs the TS
- Glow lights one HUD node per tip (the web lights every matching element, e.g. both Grimoire buttons) and follows the node live rather than only checking visibility when the card opens.
- No CSS entry animation beyond a 0.2 s fade; the keyboard card-move (arrow keys on the header) is not ported.
- Platform storage is a JSON file (`DmCounselStore`) instead of localStorage.

## Tests / shots
`godot --headless --path godot --script res://tests/onboarding/run.gd` (needs fixtures: `tools/godot/gen-fixtures.sh` or `npx vite-node tools/godot/fixtures-onboarding.ts`).
Replays 53 scripted event sequences (13 hand-written + 40 random, ~2,170 logged show/hide/glow/back/clear events and state snapshots) through the real TS `Onboarding` class and matches them exactly.
Screenshots: `tools/godot/shoot-onboarding.sh <tip id> [out.png]` -> `godot/shots/onboarding/`.
