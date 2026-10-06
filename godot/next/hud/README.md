# godot/next/hud: the real HUD and panels on the slice

The slice runs the **existing** `DmGameUi` (HUD + panels + counsel) unchanged except for one line (`warm_panels`, below). It gets there through an
adapter instead of copies: `DmNextUiHost` implements the DmGame side of `godot/GAME_CONTRACT.md` on top of `DmNextGame`, so `DmGameUi.setup(ui_host)`
works exactly as `setup(DmGame)` does. Nothing in `game_ui/`, `ui/hud/` or `ui/panels*/` knows about the slice.

```
DmNextGame.start -> _start_hud():  UiHost (DmNextUiHost) .setup(shell)   then   Ui (DmGameUi).setup(ui_host); await ui.warm()   (every DmGameUi panel is pre-built under the loading cover, as the old game)
opts.hud:  true (default) real HUD  |  "minimal" DmNextHud orbs only (fallback, used by tests/next)  |  false none (headless clients)  |  persist (user:// writes)
```

## Adapter (`dm_next_ui_host.gd`, `dm_next_hud_vm.gd`)
| Contract item | Source in the slice |
|---|---|
| `hud_state()` | `DmNextHudVm.build()`: `DmHeroBody` (hp, essence, alive, family), `DmRiteCaster` (`cooldown_left`, `p["loadout"]`), `DmThrallHost` (places, list), `DmStatusSet` (target statuses), `DmWaveDirector.enemies` (minimap, target), `DmCorpseField`, roster (party), `world.builder` (unlocked areas / open doors) |
| `character`, `progress` | the shell's character dict, shared with the rewards member's `DmProgression` (`prog.character = character`), so XP / level / gold credits land where the HUD reads |
| `slots` (bag) | `DmInventory` (the existing optimistic bag + debounced `api.save_inventory`); the rewards member's `take_item` = `_take` -> `inventory.add`, "Reliquary full" float when it is full |
| `settings` | `DmSettings` (same store/keys as the old game); `apply_settings` pushes audio, Vfx quality/reduced motion, camera reduced motion; Settings -> Loot sets `loot_view.rules` |
| loadout | `DmLoadout.load_rites(...)` = `DmContent.kit(family).defaultLoadout` + `rmb` (+ the persisted Grimoire choice). `set_rites()` from the Grimoire writes it back. One place: `ui_host.primary` / `ui_host.keys` |
| `cast(slot)` / keys / mouse | `DmNextInput.hotbar(slot, aim, enemy_id)` (LMB = 0, keys 1-4 = 1-4, key 5 and RMB = 5) -> `_on_hotbar` -> `DmRiteCaster.request_cast(rite_at(slot), aim, enemy)`. HUD slot clicks go through `cast(slot)` |
| cooldown / essence / rejection | `cooldown_left`, the body's resource, `cast_rejected(rite, reason)` -> same texts as the old game ("Not enough Grave Essence", "X is not ready", "X unlocks at level N"; busy/range/no_target stay silent), rate-limited to 1 per 600 ms; `essence_short` counsel event |
| float text | `hit_number` of every body's caster -> `float` event (kind hit / crit, y 1.6 like `DmAbilitySystem`); host `body.hurt` -> "-N" (hurt) + `hit_flash`; thrall blows (`DmEnemy.damaged` from a `DmThrall`) -> thrall; Miasma ticks (`DmStatusSet.dot_damage`) -> dot; heals, gold, shards, "Reliquary full" -> info/gold/shard/heal. Honors Settings -> damage numbers |
| toasts / banners | `game_event("toast" / "banner" / "loot" ...)` into the existing `DmGameUi._on_game_event`; level-ups from `member_credited`; loot toast from `loot_view.picked` |
| belt | heal chip counts `DmContent.healing_flasks()` in the bag; **Q** (and the Reliquary Drink) drinks one (`use_item`), elixir/tonic chips are shown empty |
| minimap | `DmHudMinimap` fed with enemies, thralls, corpses, areas/doors the slice actually built; click -> `navigate` -> `DmNextInput.click_move` |

Hook for the rites track: `_on_hotbar` checks `DmRiteCaster.RITES.has(id)` (the one line to swap for the per-rite registry). A rite on the hotbar that the caster
does not know yet gives a "X is not in the slice yet" float instead of being sent (an unknown rite is a forged intent on the host). Everything else
(icons, cost, cooldown sweep, locked, affordable) comes from `DmAbilities.def(id)` and works for any rite id. Key `1` no longer fires miasma through the
caster's `rite_1` poll (the action is not registered any more): slot 1 is whatever the loadout says (the kit: `marrow_spear`, `exhume`, `miasma`, `black_litany`, RMB `corpse_explosion`).

## Widgets reused vs changed
Reused as-is: `DmGameUi`, `DmHud` and all its parts (orbs, slots + cooldown sweep, belt chips, target frame, party, minimap, area label, toasts, banners, floating
numbers, death wash), `DmReliquaryPanel` / `DmUiInventory`, `DmUiSettings`, grimoire (`DmUiPanelsA`), counsel/onboarding, `DmInventory`, `DmSettings`, `DmLoadout`, `DmGameHud.art`.
Changed: `game_ui/dm_game_ui.gd` gains `var warm_panels` (default = the old `WARM_PANELS`; the old game is unchanged). `next/next_input.gd`: key 5, `rite_1` removed.
`next/next_game.gd` / `.tscn`: the `Hud` node is gone, `start()` builds the HUD (`hud` option). `next_hud.gd` stays as the "minimal" fallback only.

## Panels
All of `DmGameUi.WARM_PANELS` are pre-built under the loading cover (`ui.warm()`, ~1.3 s of the load). `tests/next_hud_counsel` opens each on the offline backend with the rebuild's data and runs one
basic action through the API: Bag (sort + save), Sheet, Capes & Pets (adopt a companion), Legion (Reinforce), Forge (craft; reforge quote), Salvage, Reagent shelf, Vault (deposit), Contracts (deliver),
Professions, Garden (plant), Labor (assign), Ascension (deepen a boon), Codex, Atlas, Waystone map. First opens measure 0-62 ms over an idle frame, the same as the old client (`tests/perf/panel_perf.gd`:
Capes & Pets ~52, Reagent shelf ~41, the rest <= 30; the UI code is shared).
- Still not on the slice: Depths readout beyond the stair card.

## Feeds added by the HUD/counsel track (adapter functions, `# ---- HUD / counsel feeds`)
| Feed | Source |
|---|---|
| Save chip (`vm["save"]`) | worse of `DmProgressSync.state` and `DmInventory.state`: Saved / Unsaved changes / Saving... / Save failed, retrying (warn) |
| Wave dial | `dial_wave(delta)` -> active tier (0..owned) -> `DmNextProgress.apply_progress` (director + rewards) |
| Sounds | `loot_view.dropped_sound` (lootDrop..Legendary, positioned), coin / shard on pickup, `play_loot` + the `collected` counsel event on an item pickup, hurt + lowHealth (< 30 %) on host damage; every one also raises `sfx(name)` |
| Counsel | `counsel_busy()` / `counsel_tick_ctx()` = `DmNextCounsel` (`dm_next_counsel.gd`): hurt / combat (three dead within 9 m or a boss awake) / dead flags, the tick ctx of `DmGameCombat.counsel_tick_ctx`; hurt -> `hurt_check` + the `hurt` tip |
| Legion | `buy_legion()` (the Legion panel's Reinforce and `buy_upgrade("legion")`): backend `necro_purchase`, `refresh_progress` adopts the tier + the server's purse, stats follow, standing thralls get the one-time bump. The tier raises thrall hp / damage; the thrall CAP comes from boons and weapons (rules, not the tier) |

## First-hour guidance (`next/gathering/dm_next_acre.gd`, `tests/next_acre_guide`)
The Next-step box / the Covenant dialogue read `DmGameUi.guidance_state()`: level, area, ascension, seals, `areaKills`, `totalKills`, the Prelate this run, bag, dust come straight from the shared progression / bag / character;
what the adapter now feeds besides: `skills` (a gathering level gained while gathering, from `DmNextGather.skills.changed`), `bossesBeaten` (the backend chronicle's `boss.<id>` counters mirrored into the store key the UI reads,
`DmNextChronicle.trophy_claimed`), `labor` / `contracts` (`DmGameLabor` summaries, `refresh_contracts`, the labor check and the Laborers panel). Every feed is event driven and asks the UI for a recompute at once
(`ui._guide_t = 0`); the UI's own 0.5 s tick no longer redoes the suggestion when the state, the setting and the dismissal are unchanged (`DmGuidanceHud.update` memo; `ui.last_guidance` is shared with the hub's NPC "!" poll):
state + suggestion 0.9 ms -> 0.2 ms per tick. The minimap **ping** (`vm["minimap"]["ping"]`, the web's rule: guidance + `guide_ping` on, the suggestion has a target and is elsewhere or `pingInPlace`) reads the box's own suggestion.
Counsel events the rebuild did not raise now are: `world_entered` (the welcome and the discipline's first tip), `brew_drunk`, `meal_eaten` (belt sounds), `minimap_travel` (a minimap click). Bug reports carry `release = godot-next-<version>`.
Still not raised: `corpse_near`, `sanctify_near`, `loadout_check`, `necro_weapon_changed`, `set_bonus_gained`, `omen_told`, `depths_*`, `auto_combat_cast`, `show_tips_again`.

## Gaps
- Progression persistence, upgrade tiers, level-ups and the belt are `next/progress/` (DmProgressSync, `DmNextBelt`); see its README.
- Client (non-host) peers get no real HUD yet (`hud: true` builds it for the host only); hurt numbers for a client's own damage need the vitals diff.
- No auto-combat (the HUD button is not fed); lifesteal / fortune / wisdom brews are not applied yet (damage, haste, ward, speed, essence are).
- Target frame elite chips: `_affix_chips` reads the replicated `dm_affix_list` meta (`[{id, name}]` + a blurb listing every affix, as `DmGameHud`), cached per target (rebuilt only when the target or its affix count changes).

## Tests / cost
`godot --headless --path godot --script res://tests/next_hud_counsel/run.gd` (feeds, counsel, Legion, every panel).
`godot --headless --path godot --script res://tests/next_hud/run.gd`; cost probe `tests/next_hud/perf.gd -- --hud=real|minimal|none` (numbers in the commit message / report).
