# client/next/bosses: the boss framework and all seven bosses

Gravedigger King, Bone Abbess, Drowned Congregation, Bell-Sworn Prelate, Plague Saint, Cinder Regent, Mire Mother. The brains are the pure
GDScript brains in `client/sim/bosses/` (see its README; phases at 60 / 30 %, telegraph -> resolve loop, stagger, wipe reset, arena leash); every
number is in `client/data/content/bosses.json`. This folder puts them in the world as nodes. A boss is an external entity of the combat core (kind 1) whose brain stays GDScript:
how it sits on the core (what the rites, the thralls and the hover pick see, the adds, the pools, summoning, the Covenant Seal, defeat and the tests) is client/README.md "The bosses"; in a party: "Co-op on the core".

```
DmBossHost  (node "Bosses" under DmNextGame, every peer)   summon rules, spawner, event routing, 20 Hz state, music, E key
  `- DmBoss (a plain Node3D)                                body + net state; registers with the core as an external; host pumps brain.update(dt); puppets ease from snapshots
       |- DmBossBrain (host only) <- DmBossNodeWorld       the brain, fed the core's world (heroes, the director's adds, thralls, corpses, zones)
       `- DmBossView (every peer)                          model / clips / glow (client/game/dm_boss_view.gd), fed a DmBossState
  `- DmBossFx (every peer)                                 brain events -> telegraphs, impacts, banners, sounds (client/game/dm_event_fx_boss.gd)
  `- DmBossMeta (host)                                     Covenant Seal altar choice, Empowered summons, the prize (dm_boss_meta.gd)
```
- **DmBoss** has no collider, navigation agent or state machine: it keeps what it needs of an enemy as fields (`hp`, `max_hp`, `radius`, `damaged`, `died`, `is_hittable()`), the brain owns movement, `take_damage` goes to `brain.damage`,
  `stun` staggers it for at most 0.5 s every 8 s, and the net state carries the boss's core id. `ensure_def` registers `boss_<id>` in `DmSimData.ENEMIES` at runtime. Slow / root / chill are ignored on purpose (bosses are immune).
  `is_hittable()` is false while the Mire Mother's state is `sunk`.
- **Events** (`t:"boss"`) are played on the host through `DmBossFx` and sent reliably (`_rpc_event`) so every peer draws each once. `t:"hurt"` stays host-side
  (`hero.take_damage(dmg, boss.core_id)`). Rooting events (`bury`, hands, the Congregation's grasp) call `DmHeroBody.root_for`; the Congregation's flood chills via `chillMs`.
- **Summon**: `DmBossHost.try_summon(peer, id) -> why` (`busy far shards dead unknown`); key E near the area's `summonId` interactable or a click.
  `LIVE` lists all seven; `served_areas` = graves, ossuary, nave, sanctum, cloister, pyre, fen. Cost is the boss's soul shards (`bosses.json` `shards`: King 2, Abbess 3, Congregation 4, Saint 5, Regent 6, Mire Mother 7)
  or the Prelate's bell (5 shards). The prompt belongs to `DmChapterhouse._update_prompt`. A guest pays with its own shards: `request_summon_plain`.
- **World hooks** (`dm_boss_node_world.gd`, `extends DmBossWorld`): `corpses()` / `remove_corpse` -> the core's corpse field (`devoured` Abbess, `raised` Mire),
  `cover()` -> `DmDb.sim_world()["cover"]` (Congregation pews), `echoes()` -> none (no vows: B36), `hostile_toxic_zones()` / `add_hostile_pool` / `ember_pool` -> zones of the core with the boss as source.
  Abbess niches and every other add go through `DmWaveDirector.spawn(..., area)` as core bodies; a kind the core does not run is skipped.
- **Rewards and meta**: `DmSessionRewards.on_boss_defeated` pays the members in range, with the first-kill trophy (not for the Prelate: it is the run's boss, `prog.record_prelate_kill()`): client/next/rewards/README.md "Bosses". Bosses in `DmGoldSink.EMPOWERABLE` (all but the Prelate)
  with a Covenant Seal open the HUD's boss-key prompt (`boss_key_offer`; `DmBossMeta`).
- **Audio**: `bossAwaken` / `bossDefeat` start / stop the war-drum bed; `AudioDirector.set_boss_music` follows the local hero (2 Hz check).
- **Adding a boss**: the brain already exists in `DmBossBrains`; add the id to `DmBossHost.LIVE` (and `served_areas`), make sure `bosses.json` and the area's `summonId` exist, add a
  `WARM_KINDS` entry in `dm_boss_fx.gd` for any kind whose first draw hitches, make every add a kind the core runs (`DmWaveDirector.CORE_KINDS`), and a suite on `client/tests/boss_base.gd` (see `boss_abbess.gd`) listed in
  `tools/rebuild/run-client-tests.sh`.

## Party and movement
- Boss health is `baseHp x level x difficulty x (1 + 0.3 x (players - 1))` (`DmEnemyStats.BOSS_PARTY_HP_PER_EXTRA`, served to the brain by `DmBossNodeWorld.party_hp_per_extra`); the replay world keeps the recorded 0.8. Two players x1.3, four x1.9.
- The arena level follows the party leader (`DmWaveDirector.scaling_levels`).
- Movement: the brain walks straight at its target, and on the live world (`nav_active`) each step is kept on the navmesh (a wall slides it). The target is sticky (another player must be 30 % closer to take over), a boss that closes no range for 0.6 s asks for a nav route and follows it waypoint by waypoint,
  and a player it cannot reach is skipped for 4 s. The boss has no collider, so a legion cannot body-block it.

## Tests
One suite for the King (`client/tests/boss.gd`), one for each of the other six on `boss_base.gd`, `boss_meta.gd` (the Covenant Seal, first-kill trophies), `core_boss.gd` (the core's half) and the party fights `coop.gd` and `coop_bosses.gd`: client/README.md "The bosses", "Co-op on the core".
The recorded scenarios the brains are replayed against are the old game's (44 of them).

## Known gaps
- Empowered choice is the host's own hero (a client's `request_summon` is the plain RPC); the prize claim window is the backend's (3 h).
- Pools of a boss that resets linger their remaining seconds (core zones have a lifetime, no owner to remove them).
- The Mire Mother's flood shrinks the Fen's hummocks for the brain (`FEN_FLOOD_SCALE`); the event plays the rings, and nothing eases the drawn hummocks.
- `can_ascend` after a Prelate kill is only a game event (no Altar: B36). Prelate Echoes are not played for the same reason (native/README.md "Differences from today's game").
- The Prelate tally is validated by the backend only for a bell it was told of (online `spend_shards` queues `summon_prelate`).
