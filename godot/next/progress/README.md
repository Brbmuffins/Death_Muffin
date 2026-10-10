# godot/next/progress: the slice character persists, levels, upgrades, drinks

`DmNextProgress` (child `Progress` of `DmNextGame`, host only) wires the character's progression into DmNextGame. It creates no rules of its own:
`DmProgression` (xp / level / gold / shards / kills / tiers / unlocks) and `DmProgressSync` (backend saves) are used as they are.
`DmNextBelt` (`Z`/`X`/`Q`) holds the flasks and brews.

```
start(): _start_rewards -> _start_progress: member.prog = DmProgression(character, local save) ; DmProgressSync.connect_server() ; apply_progress()
```

## What persists and how (DECISIONS.md D1 / D4 / D8)
| Value | Where it lives | Path |
|---|---|---|
| level, xp, gold, stats | backend character | `api.save_progress` (DmProgressSync `_payload`) |
| shards, kill counts (total + per area), unlocked areas, damage / wave tiers, boons, vows, ashes | backend necro-progress | `api.necro_save` (pending deltas) / `necro_purchase` (tiers, priced by the backend) |
| bag + equipment | backend inventory | `DmInventory` -> `api.save_inventory` (debounced) |
| milestone claims, best chain | local store (claims live on this machine) | `DmCounselStore` key `dm_milestones_<id>` |
`api` is the VPS `DmApi` online and `DmOffline.make_api` under `--dev-offline`: the same calls (DECISIONS.md D4, D8).
XP and kill counts arrive only from the rewards node's **accepted** session reports (`member_credited`); gold / shards / items from ground pickups. A relaunch reloads the
character from the backend (`load_or_create_character`) and `connect_server` adopts the necro state.

## Chronicle, trophies, Codex (`dm_next_chronicle.gd`, `dm_next_codex.gd`)
* **One Chronicle** (`DmNextGame.chron.chronicle`, child `Chronicle`, loaded before the progression): `prog.chronicle` is it, so kills + `kills.<area>` + `peak.wave` (DmProgression.record_kill, accepted reports only),
  `gold.earned/spent`, gathering (`gathered.<skill>`), the Depths (`depths.*`, `kills.depths`, `peak.depth`: `DmDepths.chronicle` is the same object), `deaths`, `peak.level`, `boss.<id>` (the Prelate through
  `boss_earned`, the area bosses through `claim_trophy`), `playSeconds` / `afkSeconds` (per frame float adds). Flush: every 30 s while dirty, 2 s after a boss kill, on leave (`flush_all`), and before the Codex's
  Chronicle tab reads the backend (`DmNextUiHost.flush_chronicle`); `/api/chronicle/add` only knows whitelisted keys, so nothing else is invented. An Ascension archives (`ascend`) in the same flush.
* **First-kill trophy** = the backend `boss.<id>` counter was 0 before this kill (it survives a relaunch and a new machine). Granted once: +2 shards, a rare relic, the relic rune.
* **Codex** (`DmNextGame.codex`): `dead` = an enemy kind within 40 m of the hero on its first spawn, or a boss when it wakes (`DmNextGame.codex_discover`, also called by the boss fx); `area` on entry (DmAreaFlow).
  Saved per character in the local store (`dm_codex_v1:<id>`) and mirrored into the HUD's `ui.codex_journal` through the `codex` game event (seeded when the HUD is built).
* Cost (headless): chronicle tick ~3 us/frame, codex per spawn ~1 us (known kind), milestone tier call ~5 us and only on a tier change.

## Save cadence (DmProgressSync)
Urgent on a level-up and on a purchase; 45 s timer while dirty (gold / shards / kills); on an area change (`DmNextGame.area_changed`); on quit / leave (`DmNextGame.flush_all`: last
kill batch + `session_end`, progression, bag; `main.gd` calls it on window close). Failures retry with backoff. Write-behind: a pickup costs ~4 us, a save call returns at its first await.

## Upgrades, levels
- Damage tier: `DmCharacterBuild.build(character, bag slots, prog.local)` (`DmNextGame.build_for`) -> `DmHeroBody.refresh_stats` + `DmRiteCaster.refresh_stats` (spell power x (1 + perTier * tier), keeps cooldowns / essence). The same call re-reads worn gear (bag change -> next frame, only when what is worn changed).
- Wave Speed: `DmWaveDirector.set_wave_tier(t)`: `wave_modifiers(t)` intervalMult / sizeMult / capMult on the area's wave interval / size / cap; enemy hp / damage mults at spawn from the ramped tier (`DmEnemyStats.ramp_tier`, `RAMP_S`); `rewards.wave_tier` carries xp / reward / item-chance mults and the kill reports' `tier`.
- Level-up: stats refresh, full health + essence, banner "Level N", `levelUp` sound, Grimoire toast for newly learned rites, `level_up` counsel event. Rite unlock levels come from the refreshed `stats.level`.
- Seal unlocks: `chapterhouse.check_seals()` breaks the doors when an area's kills are in (`DmChapterhouse`); without a hub node it only banks `prog.unlock` and toasts. Milestones pay their gold as a **ground drop** (`member.loot_view.gold`) through the rewards pickup path.

## Belt
`Q` heal flask (the one picked in the Heal slot of the Reliquary's potion belt while owned, else the best owned; 1.5 s sip cooldown, Dry Cellar vow forbids), `Z`/`X` elixir / tonic (picked on the belt, else any in the bag; replace / extend rules, `DmBrews.apply_brew`), meals heal over time. Brews act through `p["brews"]` on the body (ward, speed) and its caster (damage, haste, essence regen). HUD chips: `DmNextBelt.rows()`.

## Tests

`godot --headless --path godot --script res://tests/next_progress/run.gd` (dev-offline backend); chronicle / codex / trophies: `tests/next_boss_meta/run.gd`.

Vows, boons, difficulty and the Omen reach the world through `DmNextMeta.sync()` (called by `apply_progress`; `next/meta/README.md`).
