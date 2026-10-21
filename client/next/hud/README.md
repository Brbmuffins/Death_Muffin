# client/next/hud: the real HUD and panels in DmNextGame

DmNextGame runs the shared `DmGameUi` (HUD + panels + counsel in `client/game_ui/`, `client/ui/hud/`, `client/ui/panels*/`) through an adapter: `DmNextUiHost`
(`dm_next_ui_host.gd`) implements the host contract `DmGameUi` expects, on top of `DmNextGame`. Nothing in the UI folders knows about the scene.
On the combat core the adapter hears the core host's events instead of each enemy's, and `DmNextHudVm` builds the view-model from the core's bulk arrays and a few queries: where each piece of the HUD
reads from, a guest's window, the pieces and the draw-call budget are client/next/hud/CORE-INTEGRATION.md.

```
DmNextGame.start -> _start_hud():  UiHost (DmNextUiHost).setup(shell)  then  Ui (DmGameUi).setup(ui_host); await ui.warm()   (panels pre-built under the loading cover)
opts.hud:  true real HUD and panels, also for joiners  |  false none (a bare scene, headless tests)
```
`game_ui/dm_game_ui.gd` has `var warm_panels` (default `WARM_PANELS`) for this; `DmNextGame.WARM_PANELS` is the client's list (the Altar's panel is not in it: DECISIONS B36).

## Adapter (`dm_next_ui_host.gd`, `dm_next_hud_vm.gd`)
| Contract item | Source |
|---|---|
| `hud_state()` | `DmNextHudVm.build()`: `DmHeroBody` (hp, essence), `DmRiteCaster` (`cooldown_left`, loadout), the combat core (minimap dots, target frame, thralls, corpses), roster (party), the world's areas / doors. Shape: `client/ui/hud/README.md` |
| `character`, `progress` | the shell's character dict shared with the rewards member's `DmProgression` |
| bag | `DmInventory` of the loot node (`DmNextLoot`: the server's bag as answered; sips batched to `api.use_items`, sort via `api.sort_bag`, DECISIONS B25); "Reliquary full" float when full |
| `settings` | `DmSettings`; `apply_settings` pushes audio, Vfx quality / reduced motion, camera |
| loadout | `DmLoadout.load_rites` = kit `defaultLoadout` + `rmb` + the saved Grimoire choice; `set_rites()` writes it back |
| casting | `DmNextInput.hotbar(slot, aim, enemy_id)` (LMB 0, keys 1-4, key 5 and RMB 5) -> `_on_hotbar` -> `DmRiteCaster.request_cast`. A rite missing from `DmRiteRegistry` gives a "not in the slice yet" float |
| cooldown / rejection | `cast_rejected(rite, reason)` -> texts ("Not enough Grave Essence", "X is not ready", "X unlocks at level N"; busy / range / no_target silent), 1 per 600 ms |
| float text | casters' `hit_number`, the hero's `hurt`, a thrall's blow (a guest's: the host's list of them, `DmNextNet`) and a DoT's lumps from the core host's events, heals / gold / shards; goes through `DmFloatBudget` (caps, see `client/next/feel/README.md`) and honours the damage-numbers setting |
| toasts / banners | `game_event("toast" / "banner" / "loot" ...)` into `DmGameUi._on_game_event`; level-ups from `member_credited` |
| belt | Q drinks the flask picked in the Heal slot (Reliquary potion belt or a drop on the chip), else the best one owned (`use_item`); elixir / tonic chips |
| minimap | `DmHudMinimap` fed with enemies, thralls, corpses, areas / doors, the click-to-move goal (`destination`, shown while `has_target`; it is static, no `_process`); click -> `navigate` -> `DmNextInput.click_move` |
| save chip | worse of `DmProgressSync.state` and `DmInventory.state` |
| wave dial | `dial_wave(delta)` -> `DmNextProgress.apply_progress` |
| sounds | loot drop / coin / shard sounds, `play_loot`, hurt + lowHealth (< 30 %); each also raises `sfx(name)` |
| counsel | `DmNextCounsel` (`counsel_busy()` / `counsel_tick_ctx()`): hurt / combat (three dead within 9 m or a boss awake) / dead flags, its facts read from the core. Raised events include `world_entered`, `brew_drunk`, `meal_eaten`, `minimap_travel`, `enemy_spawned`, `sanctify_near`, `corpse_near`, `auto_combat_cast` (client/ui/onboarding/README.md "Tips and onboarding") |
| Legion | `buy_legion()`: backend `necro_purchase`, `refresh_progress` adopts the tier; the thrall cap comes from boons and weapons, not the tier |
| guidance | `DmGameUi.guidance_state()` reads the shared progression; the adapter feeds `skills`, `bossesBeaten` (chronicle `boss.<id>`), `labor`, `contracts` (`client/next/gathering/dm_next_acre.gd`) and recomputes at once (`ui._guide_t = 0`). The minimap ping reads the Next-step box's suggestion: with "Point to it on the minimap" on, `DmGameUi._refresh_ping` puts its target on the minimap (a place elsewhere, or here when marked `pingInPlace`), worked out when the suggestion, the area or the setting changes |
| elite chips | the target frame's chips come from the affix list of the core's body, cached per target |

**GM mode** (`_is_dev_account` / `_apply_dev_access`, setting `dev_access`, off by default): a dev account plus the Settings toggle opens rites (`DmRiteCaster.dev`), sealed halls and gathering tiers,
and tells the server (`_tell_server_gm_mode` -> `POST /api/gm/mode`), which only then skips its checks for the account, logs its saves and marks the character GM (DECISIONS B19);
F9 = `dev_break_seals()`. Bug reports carry the adapter's `release` string.

## Panels
All of `DmNextGame.WARM_PANELS` are pre-built under the loading cover (`ui.warm()`): Bag, Sheet, Capes & Pets, Legion, Forge, Salvage, Reagent shelf, Contracts, Professions, Garden, Labor, Grimoire, Codex, Atlas, Waystone map, Settings
and the Social window's Party tab. `client/tests/panels.gd` opens and closes each and checks the Reliquary (equip, sell, sort on the server's bag), the Grimoire's loadout, Settings live and chat.

## Loot (`client/next/rewards/dm_next_loot.gd`, `client/loot_view/loot_view.gd`)
The player's drops and bag are the loot node's, not the adapter's: the pickup rules, claims and rune ownership are client/next/rewards/README.md. The adapter keeps the Reliquary's Drop (DECISIONS B16): `drop_gear(row)` calls `api.ground_drop`,
adopts the server's bag, draws the piece at the hero's feet (`DmLootView.shared_item`) and relays it; `show_shared_drop` / `remove_shared_drop` are the party's side (client/next/rewards/AUTHORITY.md).

## Tests
`client/tests/hud.gd` (the view-model's pieces on the core, the draw-call model, the counsel's timers), `client/tests/panels.gd`, `client/tests/counsel.gd` (the counsel and the first hour), `client/tests/value.gd` (the belt against the bag, saving),
`client/tests/coop.gd` (a guest's window). `client/tests/hud_feeds.gd` (`HudFeeds.full()`) fills every view-model key for the tests that draw every piece. Counsel tips (queue, cadence, card): `client/ui/onboarding/README.md`.

## Known gaps
- After entering the Graves the Next line leads to the Gravedigger King until he has been beaten (B69): his shard hint is priority 65 (`DmGuidance.KING_FIRST_PRIORITY`), above the Ossuary seal (60), and "waits at the King's Grave" (86) takes over once the shards are in hand.
- Counsel events that are defined but never raised: `client/ui/onboarding/README.md`.
