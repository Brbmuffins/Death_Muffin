# godot/next/progress: the slice character persists, levels, upgrades, drinks

`DmNextProgress` (child `Progress` of `DmNextGame`, host only) is the slice-side wiring of the current game's progression. It creates no rules of its own:
`DmProgression` (xp / level / gold / shards / kills / tiers / unlocks) and `DmProgressSync` (backend saves) are used as they are.
`DmNextBelt` (`Z`/`X`/`Q`) is the slice's port of `DmGameActions` flasks and brews.

```
start(): _start_rewards -> _start_progress: member.prog = DmProgression(character, local save) ; DmProgressSync.connect_server() ; apply_progress()
```

## What persists and how (REBUILD D1 / D4 / D8)
| Value | Where it lives | Path |
|---|---|---|
| level, xp, gold, stats | backend character | `api.save_progress` (DmProgressSync `_payload`) |
| shards, kill counts (total + per area), unlocked areas, damage / wave tiers, boons, vows, ashes | backend necro-progress | `api.necro_save` (pending deltas) / `necro_purchase` (tiers, priced by the backend) |
| bag + equipment | backend inventory | `DmInventory` -> `api.save_inventory` (debounced) |
| milestone claims, best chain | local store (as the old game: "claims live on this machine") | `DmCounselStore` key `dm_milestones_<id>` |
`api` is the VPS `DmApi` online and `DmOffline.make_api` offline: the same calls, so online characters carry into the slice unchanged (D8) and offline stays on the local backend (D4).
XP and kill counts arrive only from the rewards node's **accepted** session reports (`member_credited`); gold / shards / items from ground pickups. A relaunch reloads the
character from the backend (`load_or_create_character`) and `connect_server` adopts the necro state.

## Save cadence (DmProgressSync, unchanged)
Urgent on a level-up and on a purchase; 45 s timer while dirty (gold / shards / kills); on an area change (`DmNextGame.area_changed`); on quit / leave (`DmNextGame.flush_all`: last
kill batch + `session_end`, progression, bag; `main.gd` calls it on window close). Failures retry with backoff. Write-behind: a pickup costs ~4 us, a save call returns at its first await.

## Upgrades, levels
- Damage tier: `DmCharacterBuild.build(character, bag slots, prog.local)` (`DmNextGame.build_for`) -> `DmHeroBody.refresh_stats` + `DmRiteCaster.refresh_stats` (spell power x (1 + perTier * tier), keeps cooldowns / essence). The same call re-reads worn gear (bag change -> next frame, only when what is worn changed).
- Wave Speed: `DmWaveDirector.set_wave_tier(t)`: `wave_modifiers(t)` intervalMult / sizeMult / capMult on the area's wave interval / size / cap; enemy hp / damage mults at spawn from the ramped tier (`DmEnemyStats.ramp_tier`, `RAMP_S`); `rewards.wave_tier` carries xp / reward / item-chance mults and the kill reports' `tier`.
- Level-up: stats refresh, full health + essence, banner "Level N", `levelUp` sound, Grimoire toast for newly learned rites, `level_up` counsel event. Rite unlock levels come from the refreshed `stats.level`.
- Seal unlocks are banked (`prog.unlock`) when an area's kills are in; the slice builds no door beyond the Graves, so it only toasts. Milestones pay their gold as a **ground drop** (`member.loot_view.gold`) through the rewards pickup path.

## Belt
`Q` heal flask (best owned, 1.5 s sip cooldown, Dry Cellar vow forbids), `Z`/`X` elixir / tonic (picked on the belt, else any in the bag; replace / extend rules, `DmBrews.apply_brew`), meals heal over time. Brews act through `p["brews"]` on the body (ward, speed) and its caster (damage, haste, essence regen). HUD chips: `DmNextBelt.rows()`.

## Test / perf
`godot --headless --path godot --script res://tests/next_progress/run.gd` (offline backend only).

Vows, boons, difficulty and the Omen reach the world through `DmNextMeta.sync()` (called by `apply_progress`; `next/meta/README.md`).
