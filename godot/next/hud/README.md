# godot/next/hud: the real HUD and panels on the slice

The slice runs the **existing** `DmGameUi` (HUD + panels + counsel) unchanged except for one line (`warm_panels`, below). It gets there through an
adapter instead of copies: `DmNextUiHost` implements the DmGame side of `godot/GAME_CONTRACT.md` on top of `DmNextGame`, so `DmGameUi.setup(ui_host)`
works exactly as `setup(DmGame)` does. Nothing in `game_ui/`, `ui/hud/` or `ui/panels*/` knows about the slice.

```
DmNextGame.start -> _start_hud():  UiHost (DmNextUiHost) .setup(shell)   then   Ui (DmGameUi).setup(ui_host); warm_panels = SLICE_PANELS; await ui.warm()
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
Pre-built under the loading cover (`ui.warm()`, same pre-build + apply-during-loading as the current game): **Bag (Reliquary)**, **Grimoire**, **Settings**.
All `DmGameUi` panels are constructed (they are built by `setup`, as in the old game) but only those three are laid out ahead and tested here. Left, with TODO:
- Sheet (J), Legion (Y), Forge/Salvage/Shelf (C), Professions/Garden/Labor/Contracts (P/U/H/O), Codex (K), Atlas (.), Ascension, Waystone map (M), Vault, Cosmetics: open
  and work on the offline backend in principle but need slice data (stations, NPCs, waystones, Acre areas) and are untested; `npc_interact` / `station_interact` are emitted by `next/chapterhouse/` (Reliquary, Workbench, Altar, Vault, Waystone, Acre/Wing stations verified by `tests/chapterhouse`).
- Not in the slice, hidden by omission: boss frame, kill chain, Depths readout, omen chip, Next-step guidance depends on bag/level only.

## Gaps
- Progression persistence, upgrade tiers, level-ups and the belt are `next/progress/` (DmProgressSync, `DmNextBelt`); see its README.
- Client (non-host) peers get no real HUD yet (`hud: true` builds it for the host only); hurt numbers for a client's own damage need the vitals diff.
- No auto-combat; lifesteal / fortune / wisdom brews are not applied yet (damage, haste, ward, speed, essence are); Legion tier is not bought in the slice.
- Loot drop/pickup sounds (`dropped_sound`, coin) are not forwarded to the AudioDirector.
- Target frame shows no elite affixes (the slice enemies carry no affix list yet).

## Tests / cost
`godot --headless --path godot --script res://tests/next_hud/run.gd`; cost probe `tests/next_hud/perf.gd -- --hud=real|minimal|none` (numbers in the commit message / report).
