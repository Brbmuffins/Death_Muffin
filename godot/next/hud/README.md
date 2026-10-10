# godot/next/hud: the real HUD and panels in DmNextGame

DmNextGame runs the shared `DmGameUi` (HUD + panels + counsel in `game_ui/`, `ui/hud/`, `ui/panels*/`) through an adapter: `DmNextUiHost`
(`dm_next_ui_host.gd`) implements the host contract `DmGameUi` expects, on top of `DmNextGame`. Nothing in the UI folders knows about the scene.

```
DmNextGame.start -> _start_hud():  UiHost (DmNextUiHost).setup(shell)  then  Ui (DmGameUi).setup(ui_host); await ui.warm()   (panels pre-built under the loading cover)
opts.hud:  true (default) real HUD, also for joiners  |  "minimal" DmNextHud orbs only (tests/next)  |  false none (headless clients)
```
`game_ui/dm_game_ui.gd` has `var warm_panels` (default `WARM_PANELS`) for this. `next_hud.gd` stays only as the "minimal" fallback.

## Adapter (`dm_next_ui_host.gd`, `dm_next_hud_vm.gd`)
| Contract item | Source |
|---|---|
| `hud_state()` | `DmNextHudVm.build()`: `DmHeroBody` (hp, essence), `DmRiteCaster` (`cooldown_left`, loadout), `DmThrallHost`, `DmStatusSet`, `DmWaveDirector.enemies` (minimap, target), `DmCorpseField`, roster (party), `world.builder` (areas / doors). Shape: `ui/hud/README.md` |
| `character`, `progress` | the shell's character dict shared with the rewards member's `DmProgression` |
| bag | `DmInventory` (optimistic bag + debounced `api.save_inventory`); "Reliquary full" float when full |
| `settings` | `DmSettings`; `apply_settings` pushes audio, Vfx quality / reduced motion, camera; Settings -> Loot sets `loot_view.rules` |
| loadout | `DmLoadout.load_rites` = kit `defaultLoadout` + `rmb` + the saved Grimoire choice; `set_rites()` writes it back |
| casting | `DmNextInput.hotbar(slot, aim, enemy_id)` (LMB 0, keys 1-4, key 5 and RMB 5) -> `_on_hotbar` -> `DmRiteCaster.request_cast`. A rite missing from `DmRiteRegistry` gives a "not in the slice yet" float |
| cooldown / rejection | `cast_rejected(rite, reason)` -> texts ("Not enough Grave Essence", "X is not ready", "X unlocks at level N"; busy / range / no_target silent), 1 per 600 ms |
| float text | casters' `hit_number`, host `body.hurt`, thrall blows, `dot_damage`, heals / gold / shards; goes through `DmFloatBudget` (caps, see `feel/README.md`) and honours the damage-numbers setting |
| toasts / banners | `game_event("toast" / "banner" / "loot" ...)` into `DmGameUi._on_game_event`; level-ups from `member_credited` |
| belt | Q drinks the best heal flask (`use_item`); elixir / tonic chips |
| minimap | `DmHudMinimap` fed with enemies, thralls, corpses, built areas / doors, the click-to-move goal (`destination`, shown while `has_target`; it is static, no `_process`); click -> `navigate` -> `DmNextInput.click_move` |
| save chip | worse of `DmProgressSync.state` and `DmInventory.state` |
| wave dial | `dial_wave(delta)` -> `DmNextProgress.apply_progress` |
| sounds | loot drop / coin / shard sounds, `play_loot`, hurt + lowHealth (< 30 %); each also raises `sfx(name)` |
| counsel | `DmNextCounsel` (`counsel_busy()` / `counsel_tick_ctx()`): hurt / combat (three dead within 9 m or a boss awake) / dead flags. Raised events include `world_entered`, `brew_drunk`, `meal_eaten`, `minimap_travel`, `enemy_spawned`, `sanctify_near`, `corpse_near`, `auto_combat_cast` |
| Legion | `buy_legion()`: backend `necro_purchase`, `refresh_progress` adopts the tier; the thrall cap comes from boons and weapons, not the tier |
| guidance | `DmGameUi.guidance_state()` reads the shared progression; the adapter feeds `skills`, `bossesBeaten` (chronicle `boss.<id>`), `labor`, `contracts` (`next/gathering/dm_next_acre.gd`) and recomputes at once (`ui._guide_t = 0`). The minimap ping reads the Next-step box's suggestion |
| elite chips | `_affix_chips` reads the replicated `dm_affix_list` meta, cached per target |

**Dev access** (`_is_dev_account` / `_apply_dev_access`): a dev account plus the Settings toggle opens rites (`DmRiteCaster.dev`), sealed halls and gathering tiers;
F9 = `dev_break_seals()`. `main/qa_driver.gd` (`-- --qa`) drives DmNextGame. Bug reports carry `release = godot-next-<version>`.

## Panels
All of `DmGameUi.WARM_PANELS` are pre-built under the loading cover (`ui.warm()`, ~1.3 s of the load). `tests/next_hud_counsel` opens each and runs one basic action
through the API: Bag, Sheet, Capes & Pets, Legion, Forge, Salvage, Reagent shelf, Vault, Contracts, Professions, Garden, Labor, Ascension, Codex, Atlas, Waystone map.
First opens cost 0-62 ms over an idle frame (Capes & Pets ~52, Reagent shelf ~41, the rest <= 30; headless, software GL).

## Loot feedback (`dm_next_ui_host.gd`, `loot_view/loot_view.gd`; test `tests/next_loot/run.gd`)
- Rule "Sell for gold" pays the purse (`auto_sold`) with a "+Ng name" float and the coin sound; rule "Auto-loot" gives the walk-over feedback. `keep` comes from `DmItemText.keeps_for_you`, so the gold rule never sells upgrades.
- Gold / shards walked over in one frame give one float and one sound.
- Bag full: "Reliquary full" float plus one toast; re-armed once there is room.
- Pickup toast colour = beam colour; better-than-worn gear says "(upgrade)".
- Ground: item names in rarity colour within 7 m (3 m ordinary; `DmLootView.near_labels = false` turns them off), icon is the inventory's own item art (`DmUiArt.item`; a rarity tile only for an item without art) and blinks in the last 8 s, drops from one kill land >= 0.65 m apart. Loot never flies to you.

## Tests
`tests/next_hud_counsel/run.gd` (feeds, counsel, Legion, every panel), `tests/next_hud/run.gd`, `tests/next_polish/run.gd`, `tests/next_acre_guide/run.gd`. Cost probe:
`tests/next_hud/perf.gd -- --hud=real|minimal|none`. State + suggestion per guidance tick: 0.2 ms. Counsel tips (queue, cadence, card): `ui/onboarding/README.md`.

## Known gaps
- After entering the Graves the Next line is "Ossuary seal: 0/300 kills" (shared `DmGuidance`, priority 60); a softer first goal means changing the shared rules. The Gravedigger shard hint is priority 50, so it only shows once shards are in hand.
- No Depths readout beyond the stair card and the HUD depth chip.
- Counsel events that are defined but never raised: see `ui/onboarding/README.md`.
