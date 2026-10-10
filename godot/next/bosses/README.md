# godot/next/bosses: the boss framework and all seven bosses

Gravedigger King, Bone Abbess, Drowned Congregation, Bell-Sworn Prelate, Plague Saint, Cinder Regent, Mire Mother. The brains are the pure
GDScript brains in `godot/sim/bosses/` (see its README; phases at 60 / 30 %, telegraph -> resolve loop, stagger, wipe reset, arena leash); every
number is in `data/content/bosses.json`. This folder puts them in the world as nodes.

```
DmBossHost  (node "Bosses" under DmNextGame, every peer)   summon rules, spawner, event routing, 20 Hz state, music, E key
  `- DmBoss (DmEnemy subclass, boss.tscn)                  body + net state; host pumps brain.update(dt); puppets ease from snapshots
       |- DmBossBrain (host only) <- DmBossNodeWorld       the brain, fed live nodes (players, director adds, thralls, corpses, pools)
       `- DmBossView (every peer)                          model / clips / glow (game/dm_boss_view.gd), fed a DmBossState
  `- DmBossFx (every peer)                                 brain events -> telegraphs, impacts, banners, sounds (game/dm_event_fx_boss.gd)
  `- DmBossMeta (host)                                     Covenant Seal altar choice, Empowered summons, the prize (dm_boss_meta.gd)
```
- **DmBoss extends DmEnemy**, so rites, thralls, statuses, rewards signals and hover pick work unchanged. It overrides `_physics_process` (the brain owns
  movement), `take_damage` (-> `brain.damage`), `stun` (<= 0.5 s stagger, 8 s ICD) and the net state. `ensure_def` registers `boss_<id>` in `DmSimData.ENEMIES` at runtime.
  Slow / root / chill are ignored on purpose (bosses are immune). `is_hittable()` is false while the Mire Mother's state is `sunk`.
- **Events** (`t:"boss"`) are played on the host through `DmBossFx` and sent reliably (`_rpc_event`) so every peer draws each once. `t:"hurt"` stays host-side
  (`hero.take_damage`). Rooting events (`bury`, hands, the Congregation's grasp) call `DmHeroBody.root_for`; the Congregation's flood chills via `chillMs`.
- **Summon**: `DmBossHost.try_summon(peer, id) -> why` (`busy far shards dead unknown`); key E near the area's `summonId` interactable or a click.
  `LIVE` lists all seven; `served_areas` = graves, ossuary, nave, sanctum, cloister, pyre, fen; `ADDS` lists the defs the brains spawn (for `warm()`).
  Cost is boss shards (King 2, Abbess 3, Congregation 4) or the Prelate's bell (5 shards). The prompt belongs to `DmChapterhouse._update_prompt`.
- **World hooks** (`dm_boss_node_world.gd`, `extends DmBossWorld`): `corpses()` / `remove_corpse` -> `DmCorpseField` (`devoured` Abbess, `raised` Mire),
  `cover()` -> `DmDb.sim_world()["cover"]` (Congregation pews), `echoes()` -> the summoner's `prelate_echo` vow, `hostile_toxic_zones()` /
  `add_hostile_pool` / `ember_pool` -> `DmBossHost.spawn_pool` (a host-damaging `DmHostileZone`; other peers get a visual-only copy by reliable RPC).
  Abbess niches are director enemies of kind `niche` (`enemies/niche.tscn`, `DmEnemyNiche`); adds go through `DmWaveDirector.spawn(..., area)`.
- **Rewards**: `DmSessionRewards.on_boss_defeated({boss, x, z, killer})`: normal-kill range rule, `DmLoot.roll_boss`, first-kill trophy (+2 shards, rare relic, relic rune; via
  `DmNextChronicle.claim_trophy`), XP, ground drops, and a `reporter.boss(...)` entry in the next `session_report`. The Prelate has no trophy: it is the run's boss
  (`prog.record_prelate_kill()`).
- **Meta** (`DmBossMeta`): bosses in `DmGoldSink.EMPOWERABLE` (all but the Prelate) with a Covenant Seal open the HUD's boss-key prompt (`boss_key_offer`);
  `summon_boss` / `summon_boss_empowered` -> `/api/boss-key/summon` (the backend takes the Seal and 7,500 x shards^2 gold, or a bound summon is free) ->
  `try_summon(peer, id, true)` (level +6 +15 %, hp x1.4). The kill report carries `summon`, then the prize is claimed (`/api/boss-key/claim`) and dropped at the corpse.
- **Audio**: `bossAwaken` / `bossDefeat` start / stop the war-drum bed; `AudioDirector.set_boss_music` follows the local hero (2 Hz check).
- **Adding a boss**: the brain already exists in `DmBossBrains`; add the id to `LIVE` (+ `ADDS`), make sure `bosses.json` and the area's `summonId` exist, add a
  `WARM_KINDS` entry in `dm_boss_fx.gd` for any kind whose first draw hitches, and a part `tests/next_bosses/<boss>_part.gd` on `harness.gd` (see `abbess_part.gd`), added to `PARTS` in `run.gd`.

## Tests
`tests/next_bosses/`: ONE process, `run.gd`, runs the parts `gravedigger_part.gd` (framework + King, owns the shared thrall / replication / perf probes), `abbess_part.gd`, `congregation_part.gd`, `prelate_part.gd`, `saint_part.gd`, `regent_part.gd`, `mire_part.gd` on one solo game and one host+client pair (shared base `harness.gd`; `BOSS_ONLY=mire,saint` runs a subset); meta-progression in `tests/next_boss_meta/run.gd`. Screenshots: `shot.gd`, `shot_cathedral.gd --boss=...`
(`--probe=1` times the first draw of each event kind), `shot_late.gd`. Typical cost (headless, printed as INFO by the suite, not asserted): brain tick 30-70 us, whole frame +0.0-0.2 ms.

## Known gaps
- Empowered choice is the host's own hero (a client's `request_summon` is the plain RPC); the prize claim window is the backend's (3 h).
- A late joiner does not see pools already burning (the RPC is at creation); pools of a boss that resets linger their remaining seconds.
- The Congregation flood's hummock shrink is an event the world builder does not ease; `can_ascend` is only a game event.
- The first draw of the six-walker Procession spawn costs one slow frame under software GL (not measured on a GPU).
- The Prelate tally is validated by the backend only for a bell it was told of (online `spend_shards` queues `summon_prelate`).
