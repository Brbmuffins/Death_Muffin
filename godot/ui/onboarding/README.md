# Covenant counsel (godot/ui/onboarding)

The tip queue, cadence rules, card and glow that guide a new player. Tip text, kinds, groups, priorities, places and anchors live in `godot/data/onboarding/tips.json` (120 tips), read through `DmCounselData`.

| file | role |
|---|---|
| `dm_counsel_data.gd` (`DmCounselData`) | tips, anchors, `render_text`, `kind_of` / `group_of` / `priority_of` |
| `dm_counsel_cadence.gd` (`DmCounselCadence`) | `can_show`, `pick_next`, `prune`, `should_preempt`, `should_yield`, `show_ms` |
| `dm_counsel.gd` (`DmCounsel`) | the queue: `show`, `pump`, `send_back`, `present`, `dismiss`, `reset`, `clear`, hover pause |
| `dm_counsel_events.gd` (`DmCounselEvents`) | event id -> tips table; ctx keys are documented in the comments of that file |
| `dm_counsel_store.gd` (`DmCounselStore`) | JSON file store (`dm_tips_v1_<char>`, `dm_counsel_position_v1`) |
| `dm_counsel_view.gd` (`DmCounselView`) | the card and glow; uses `DmTipCard` and `DmHud.tip_anchor_rect` / `tip_default_position` |

## Wiring
`DmGameUi` (`game_ui/dm_game_ui.gd`) owns the store, `DmCounsel` and `DmCounselView`. In DmNextGame the host side is `next/hud/dm_next_counsel.gd`
(`counsel_busy()`, `counsel_tick_ctx()`), and gameplay systems raise events through the UI host: `counsel.notify(event_id, ctx)`, plus
`counsel.notify_tick(ctx)` every 400 ms. Settings: "Don't show tips" -> `tips_disabled` signal; `set_tips_enabled(bool)`; "Show tips again" ->
`show_tips_again(...)`. `counsel.card_shown` drives the counsel-card sound. `busy` = `{combat, hurt, talking, banner, dead, panel, area, safe}`; stop calling
`tick` while paused.

## Behaviour
- One card at a time. Calm cards wait for quiet (no fight, talk, banner or panel; 20 s after the last card; 3 s at session start), danger cards show in fights,
  asked cards promptly; 150 s subject groups (40 s for enemy / lesson); stale tips pruned; calm backlog capped at 4.
- A card yields to fights / talk / panels after 6 s, is preempted by Hurt? / fight lessons after 5 s, leaves with the hero for place tips, and returns to the front of the queue when it yields.
- Card: 25-40 s (fight cards 14 s+), timer pauses on hover / drag, click dismisses, header drags (position saved, clamped 8 px in).
- Glow: 2 px outline with a pulsing halo (1.4 s); `reduce_motion` holds it steady. It lights one HUD node per tip and follows the node live.
  Anchor aliases: brew -> belt, bag_full / bag_filling -> relic, skill_up -> gather.

## Tests
`godot --headless --path godot --script res://tests/onboarding/run.gd` replays 53 scripted event sequences (13 hand-written + 40 random) through the
GDScript counsel and matches the recorded logs, checks cadence decisions, text rendering and the event table against `tests/onboarding/fixtures/*.json`.
The fixtures are frozen (no generator). Screenshots: `tools/godot/shoot-onboarding.sh <tip id> [out.png]`.

## Known gaps
- Events defined in `DmCounselEvents` but never raised: `depths_solo`, `depths_floor`, `depths_affix`, `loadout_check`, `necro_weapon_changed`, `set_bonus_gained`, `omen_told`.
- The keyboard card-move (arrow keys on the header) is not ported; no entry animation beyond a 0.2 s fade.
