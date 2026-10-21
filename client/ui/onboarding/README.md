# Covenant counsel (client/ui/onboarding)

The tip queue, cadence rules, card and glow that guide a new player. Tip text, kinds, groups, priorities, places and anchors live in `client/data/onboarding/tips.json` (122 tips), read through `DmCounselData`.

| file | role |
|---|---|
| `dm_counsel_data.gd` (`DmCounselData`) | tips, anchors, `render_text`, `kind_of` / `group_of` / `priority_of` |
| `dm_counsel_cadence.gd` (`DmCounselCadence`) | `can_show`, `pick_next`, `prune`, `should_preempt`, `should_yield`, `show_ms` |
| `dm_counsel.gd` (`DmCounsel`) | the queue: `show`, `notify`, `notify_tick`, `dismiss`, `skip`, `reset`, `clear`, `pause_card` / `resume_card` (hover pause) |
| `dm_counsel_events.gd` (`DmCounselEvents`) | event id -> tips table; ctx keys are documented in the comments of that file |
| `dm_counsel_gear.gd` (`DmCounselGear`) | the gear moments: `observe(slots, discipline_id)` -> `necro_weapon_changed` / `set_bonus_gained` events from the worn rows, against the last bag it saw |
| `dm_counsel_store.gd` (`DmCounselStore`) | JSON file store (`dm_tips_v1_<char>`, `dm_counsel_position_v1`) |
| `dm_counsel_view.gd` (`DmCounselView`) | the card and glow; uses `DmTipCard` and `DmHud.tip_anchor_rect` / `tip_default_position` |

## Wiring
`DmGameUi` (`client/game_ui/dm_game_ui.gd`) owns the store, `DmCounsel` and `DmCounselView`. In DmNextGame the host side is `client/next/hud/dm_next_counsel.gd`
(`counsel_busy()`, `counsel_tick_ctx()`: it asks the combat core for its fight facts on the 400 ms poll), and gameplay systems raise events through the UI host: `counsel.notify(event_id, ctx)`, plus
`counsel.notify_tick(ctx)` every 400 ms. Which facts the core's events give the counsel, the first hour (the welcome, the Next-step box, the Prior) and the Altar's tips held back: "Tips and onboarding" below. Settings: "Don't show tips" -> `tips_disabled` signal; `set_tips_enabled(bool)`; "Show tips again" ->
`show_tips_again(...)`. `counsel.card_shown` drives the counsel-card sound. `busy` = `{combat, hurt, talking, banner, dead, panel, area, safe}`; stop calling
`tick` while paused.

## Behaviour
- One card at a time. Calm cards wait for quiet (no fight, talk, banner or panel; 20 s after the last card; 3 s at session start), danger cards show in fights,
  asked cards promptly; 150 s subject groups (40 s for enemy / lesson); stale tips pruned; calm backlog capped at 4.
- A card yields to fights / talk / panels after 6 s, is preempted by Hurt? / fight lessons after 5 s, leaves with the hero for place tips, and returns to the front of the queue when it yields.
  A card that takes another's place appears alone: the one it replaces is removed at once instead of fading out under it (`DmCounselView`).
- Card: 25-40 s (fight cards 14 s+), timer pauses on hover / drag, click dismisses, header drags (position saved, clamped 8 px in).
- Glow: 2 px outline with a pulsing halo (1.4 s); `reduce_motion` holds it steady. It lights one HUD node per tip and follows the node live.
  Anchor aliases: brew -> belt, bag_full / bag_filling -> relic, skill_up -> gather.
- What it costs a frame: the clock waits for the earliest timer due instead of scanning the timers, a card on screen is compared only with the urgent and danger tips waiting (the only ones that can take its place), and the card's draining line is drawn once and squeezed
  by a scale (`DmTipCard.show_timer`) instead of redrawn every frame (client/ui/hud/PERFORMANCE.md, CPU).

## Tips and onboarding

The counsel is `DmCounsel` (the tip queue in `ui/onboarding`: kinds, groups, places, cadence, the card and its glow), owned by `DmGameUi`; it is cheap to wait with ([The HUD's budget](../hud/PERFORMANCE.md), CPU: the clock waits for its earliest timer, a card on screen is compared with the urgent tips alone, the card's line is drawn once). It is fed through `DmNextUiHost.game_event` and polled every
400 ms; `data/onboarding/tips.json` has the 122 tips and `DmCounselEvents` the table from a fact to its tips. What reads creatures is the counsel's host side, `DmNextCounsel`, and the few facts the creatures give it.
Neither has a node or a call per creature: both are the core host's events and one timer.

| fact | where it comes from | tips |
|---|---|---|
| a body spawned within 40 m (`enemy_spawned {def, elite, near, area_safe}`) | the host's `enemy_spawned`, once for each, in `DmNextUiHost._on_enemy_spawned` | the kind's first sight, move, elite, deacon |
| a corpse laid (`corpse_near {area_safe, dist}`) | `corpse_added` | exhume (within 12 m, outside a safe place) |
| a Deacon blessed a body (`sanctify_near {dist}`) | the `sanctify` cue | sanctify (within 18 m) |
| the hero hurt (`hurt_check {hp, max_hp}` each blow, the `hurt` tip below half health) | the hero's `hurt` signal | hurt |
| a cast refused for essence (`essence_short`) | the caster's rejection | essence |
| a fight: three living dead within 9 m of the hero, or the boss awake | `DmNextCounsel`, on the poll | holds calm tips back (`busy.combat`); the Grimoire's rune swap (`in_combat`) |
| corpses within 7 m, a pack of three on a corpse, the thralls he owns | `DmNextCounsel`, on the poll | thrall, litany, burst |
| kills, shards, gold, the bag, a boss site or a closed door near, the unlock set | the progression and the bag, on the poll | codex, wave, prelate, belt, tool, boss sites, gate |
| the bag changed (`bag_changed` with the rites learned and the runes owned) and a level-up (`level_up`, which `DmGameUi` gives the same two counts) | `DmGameUi._on_inventory_changed` and `_on_game_event` | loadouts (six rites or two runes) |
| the worn main-hand line changed (`necro_weapon_changed {main, was_main}`, not for a staff or taking it off) and an armor set bonus switched on (`set_bonus_gained {gained}`) | `DmCounselGear`, asked for each bag change by `DmGameUi._on_inventory_changed`: the first bag it sees is only remembered | necroWeapon, setBonus |
| the hero stands in a hunting ground (`omen_told`, the Omen's chip is on screen there) | `DmGameUi`, on `area_changed` outside a safe place | omen (150 s later; dropped if he stands in a safe place when it falls due, told again at the next hunting ground) |
| a Depths run began or the stair refused a party (`depths_solo`), a floor stands (`depths_floor`, and `depths_affix {extras}` from the first depth with extra affixes), the chest opened (`depths_chest`) | `DmDepths` (`enter`, `_refused`, `_load_floor`, `open_chest`) | the Depths' four tips |

`DmNextCounsel.tick_ctx` (DmGameUi's 400 ms timer) asks the core: one radius query for the fight (the core measures to the edge, which finds everything the centre test finds, so a candidate is confirmed by
its centre: a rising or burrowed body counts, a dead one does not), `corpses_in_radius` for the corpses and, for each, one more query for its pack, `thrall_count` for the legion: 0.18 ms a poll with
72 bodies and 30 corpses around the hero (`tests/counsel.gd`, INFO). The busy flags (`counsel_busy`, 10 Hz) are two time stamps and the hero's `alive`.

**The first hour.** `world_entered {family, level, grimoire_unlocked}` is raised once at the end of `DmNextGame.start` (the welcome tip; from level 10 the signature, with the Grimoire unlocked the Grimoire tip).
The welcome tip is a tip of the Acre (`HERE` in the tips data), so a new hero meets the belt's tip first (the bag's flask) and the welcome when he walks into the Acre. The Next-step box (`DmGuidanceHud`), the
Prior's greeting and advice (`DmCovenantDialogue` over the same `guidance_state`), the HUD's progressive reveal, the NEW cues, Settings' "Show tips again" and "Don't show tips" (kept with the account) are
`DmGameUi`'s; a party joiner whose kills the backend will not credit is told at the end of `start`. The poll says `altar: false` (`DmCounselEvents.tick_calls`),
because the game has no Altar of Ascension (B36), which holds back the vows, altar_unlocks and boons tips; `can_ascend` (the Prelate's fall) stays unraised too (`ui/onboarding/README.md`).

`tests/counsel.gd` plays it on the whole world as a new Gravecaller: the poll against a brute-force reading of the core's tables (24 seeded placements, and the edges by hand: bodies whose edges are within 9 m and
whose centres are not), every fact above through the real scene, each tip queued and shown once, the state-driven tips one fact at a time, the welcome held for the Acre, the
Next-step box, the Prior, the reveal, an area's first entry, no Altar tips, Show tips again and Don't show tips, then the Omen, the loadouts tip at the bag and at a level-up, and a new weapon line and a set bonus through the Reliquary's equip path; `tests/depths.gd` the Depths' tips, `tests/onboarding` `DmCounselGear` on its own.

## Tests
`client/tests/counsel.gd` plays the counsel on the whole world as a new Gravecaller (the fight facts read two ways, every fact the creatures give the counsel once, each tip queued and shown once, the state-driven tips, the welcome and the Next-step box, the Prior,
Show tips again, Don't show tips, the Omen, the loadouts tip, a new weapon line and a set bonus); `client/tests/depths.gd` the Depths' tips; `client/tests/onboarding/run.gd` the table, the cadence and `DmCounselGear`; `client/tests/hud.gd` the counsel's timers.

## Known gaps
- The Altar's tips (vows, altar_unlocks, boons) are held back by `DmCounselEvents.tick_calls`' `altar` flag, which the client's poll sets to false (DECISIONS B36).
- The keyboard card-move (arrow keys on the header) is not ported; no entry animation beyond a 0.2 s fade.
