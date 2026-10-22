# client/next/progress: the character persists, levels, upgrades, drinks

`DmNextProgress` (child `Progress` of `DmNextGame`, host only) wires the character's progression into DmNextGame. It creates no rules of its own:
`DmProgression` (xp / level / gold / shards / kills / tiers / unlocks) and `DmProgressSync` (backend saves) are used as they are.
`DmNextBelt` (`Z`/`X`/`Q`) holds the flasks and brews. Its bag is the loot node's (`DmNextLoot`, client/next/rewards/README.md), or the server's rows the game started with until that exists.

```
start(): _start_rewards -> _start_progress: member.prog = DmProgression(character, local save) ; DmProgressSync.connect_server() ; apply_progress()
```

## What persists and how (DECISIONS.md D1 / D4)
| Value | Where it lives | Path |
|---|---|---|
| level, xp, gold, stats | backend character | `api.save_progress` with **gains** (DmProgressSync `save_gains`, DECISIONS B23): what was earned since the last acknowledged save (`prog.xp_unsent` / `gold_unsent`) under a `seq`; the backend adds it to its record and answers its totals, which the client adopts (`adopt_server_totals`) plus what is still unsent. Gold a route pays itself (gathering, labor, contracts, selling, purchases) comes back as a total too (`credit_server_gold` / `adopt_server_gold`) |
| shards, kill counts (total + per area), unlocked areas, damage / wave tiers | backend necro-progress | `api.necro_save` (pending deltas) / `necro_purchase` (tiers, priced by the backend). The vows, boons and ashes the record also holds are not read or written (DECISIONS B36) |
| bag + equipment | backend inventory | server operations only (DECISIONS B25); `DmInventory` shows the server's answers, sips -> `api.use_items` (debounced) |
| milestone claims, best chain | local store (claims live on this machine) | `DmCounselStore` key `dm_milestones_<id>` |
`api` is the live `DmApi` and `DmOffline.make_api` under `--dev-offline`: the same calls (DECISIONS.md D4).
XP and kill counts arrive only from the rewards node's **accepted** session reports (`member_credited`); gold / shards / items from ground pickups. A relaunch reloads the
character from the backend (`load_or_create_character`) and `connect_server` adopts the necro state.

## Chronicle, trophies, Codex (`dm_next_chronicle.gd`, `dm_next_codex.gd`)
* **One Chronicle** (`DmNextGame.chron.chronicle`, child `Chronicle`, loaded before the progression): `prog.chronicle` is it, so kills + `kills.<area>` + `peak.wave` (DmProgression.record_kill, accepted reports only),
  `gold.earned/spent`, gathering (`gathered.<skill>`), the Depths (`depths.*`, `kills.depths`, `peak.depth`: `DmDepths.chronicle` is the same object), `deaths`, `peak.level`, `boss.<id>` (the Prelate through
  `boss_earned`, the area bosses through `claim_trophy`), `playSeconds` / `afkSeconds` (per frame float adds). Flush: every 30 s while dirty, 2 s after a boss kill, on leave (`flush_all`), and before the Codex's
  Chronicle tab reads the backend (`DmNextUiHost.flush_chronicle`); `/api/chronicle/add` only knows whitelisted keys, so nothing else is invented.
* **First-kill trophy** = the backend `boss.<id>` counter was 0 before this kill (it survives a relaunch and a new machine). Granted once: +2 shards, a rare relic, the relic rune.
* **Codex** (`DmNextGame.codex`): `dead` = an enemy kind within 40 m of the hero on its first spawn (the core host's `enemy_spawned`), or a boss when it wakes (`bosses.boss_spawned`); `area` on entry (DmAreaFlow).
  Saved per character in the local store (`dm_codex_v1:<id>`) and mirrored into the HUD's `ui.codex_journal` through the `codex` game event (seeded when the HUD is built).

## Save cadence (DmProgressSync)
Urgent on a level-up and on a purchase; 45 s timer while dirty (gold / shards / kills); on an area change (`DmNextGame.area_changed`); on quit / leave (`DmNextGame.flush_all`: last
kill batch + `session_end`, progression, bag; `main.gd` calls it on window close). Failures retry with backoff. Write-behind: a pickup costs ~4 us, a save call returns at its first await.

## Upgrades, levels
- Damage tier: `DmCharacterBuild.build(character, bag slots, prog.local)` (`DmNextGame.build_for`) -> `DmHeroBody.refresh_stats` + `DmRiteCaster.refresh_stats` (spell power x (1 + perTier * tier), keeps cooldowns / essence). The same call re-reads worn gear (bag change -> next frame, only when what is worn changed).
- Wave Speed: `DmWaveDirector.set_wave_tier(t)`: `wave_modifiers(t)` intervalMult / sizeMult / capMult on the area's wave interval / size / cap; enemy hp / damage mults at spawn from the ramped tier (`DmEnemyStats.ramp_tier`, `RAMP_S`); `rewards.wave_tier` carries xp / reward / item-chance mults and the kill reports' `tier`.
- Level-up: stats refresh, full health + essence, banner "Level N", `levelUp` sound, Grimoire toast for newly learned rites, `level_up` counsel event. Rite unlock levels come from the refreshed `stats.level`.
- Seal unlocks: `chapterhouse.check_seals()` breaks the doors when an area's kills are in (`DmChapterhouse`); without a hub node it only banks `prog.unlock` and toasts. Milestones pay their gold as a **ground drop** (`member.loot_view.gold`) through the rewards pickup path.

## Belt
`Q` heal flask (the one picked in the Heal slot of the Reliquary's potion belt while owned, else the best owned; 1.5 s sip cooldown; the Dry Cellar vow's ban on flasks is Ascension's and does not act), `Z`/`X` elixir / tonic (picked on the belt, else any in the bag; replace / extend rules, `DmBrews.apply_brew`), meals heal over time. Brews act through `p["brews"]` on the body (ward, speed) and its caster (damage, haste, essence regen). HUD chips: `DmNextBelt.rows()`; the chips' bag counts and picks are made again only when the bag was replaced or a pick changed (one pass over the bag). A party guest has the same belt on its own bag (`remote_use`; the host applies the drink, `client/next/party/README.md`); `DmNextGame.belt()` is whichever the local hero has.

## Tests

`client/tests/value.gd` plays it on the game scene against the mock backend (kills through the core, the accepted XP and counts, the purse, a drop claimed into the bag, brews and lifesteal, the meta, Q's flask, the save on leave, the belt chips against the bag);
`client/tests/boss_meta.gd` the first-kill trophies.

Difficulty, the Omen and the Soul Harvest reach the world through `DmNextMeta.sync()` (called by `apply_progress`; `client/next/meta/README.md`).
