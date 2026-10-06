# godot/next/bosses: the boss framework + the Gravedigger King, Plague Saint, Cinder Regent, Mire Mother

Suite: `godot --headless --path godot --script res://tests/next_bosses/run.gd`. Screenshots: `tests/next_bosses/shot.gd` (header has the render-lock command).

## Design (and why the old brains are reused)

The seven brains of `godot/sim/bosses/` (`DmBossBrain` + per-boss `_think/_resolve/_tick/_on_phase`) are pure RefCounted logic over a tiny world interface
(`DmBossWorld`: players, spawn_enemy, thralls, emit ...) with every number from `content/bosses.json`. They already contain the phases (60/30 %), the
telegraph -> resolve loop, stagger, wipe reset and the arena leash. Rewriting them as node state machines would copy ~1,000 lines for no gain, so a boss is:

```
DmBossHost  (node "Bosses" under DmNextGame, every peer)   summon rules, spawner, event routing, 20 Hz state, music, E key
  `- DmBoss (DmEnemy subclass, scene boss.tscn)             body + net state; host: pumps brain.update(dt); puppet: eased from snapshots
       |- DmBossBrain (host only)  <- DmBossNodeWorld       the existing brain, fed live nodes (players, director adds, thralls)
       `- DmBossView  (every peer)                          the CURRENT client's boss model / clips / glow (game/dm_boss_view.gd), fed a DmBossState
  `- DmBossFx (every peer)                                  the current client's boss events (DmEventFx -> DmEventFxBoss): telegraphs, impacts, banners, sounds
```
* **DmBoss extends DmEnemy**, so rites (`take_damage`, `is_hittable`, `radius`, `hp`), thralls (group `dm_enemy`), statuses (`DmStatusSet.attach`), the rewards
  `died/damaged` signals and the hover pick work with no new code. It overrides `_physics_process` (the brain owns movement: open arenas, no navmesh),
  `_build_states` (label-only states IDLE/CHASE/ATTACK/DEAD driven by the brain's state string), `take_damage` (-> `brain.damage`, defeat is reported at once),
  `stun` (<= 0.5 s stagger, 8 s ICD), `get/apply_net_state` (+ phase, max hp, brain state, live telegraphs `[kind, seconds_left, radius]`).
  `DmBoss.ensure_def` registers a `boss_<id>` entry in `DmSimData.ENEMIES` at runtime (DmEnemy._ready needs a def) so no shared data file changed.
* **Events** (`t:"boss"` from the brain) are the telegraph/impact/phase/defeat stream: the host plays them through `DmBossFx` and sends them reliably to the other
  peers (`_rpc_event`), so every peer draws each exactly once, with the brain's own `ms` as the timing. `t:"hurt"` is a host-side consequence
  (`hero.take_damage(dmg, boss)`), never sent. `bury` with `root` calls `DmHeroBody.root_for(s)`. `signal brain_event(ev, boss)` mirrors all of them (tests, HUD).
* **State** (20 Hz, unreliable): pos, yaw, hp, max hp, phase, brain state, empowered, telegraphs, DmEnemy state id. A late joiner's first phase-3 snapshot replays the pits.
* **Summon** (`DmBossHost.try_summon(peer, id) -> why`; any peer asks through `request_summon`, key E near the grave, prompt toast within 5 m): hero alive, within 4 m of
  the area's `summonId` interactable, no other boss awake, the member's `prog.spend_boss_shards(id)` (2 for the King). Refusals: `busy far shards dead unknown`.
* **Rewards**: `DmSessionRewards.on_boss_defeated({boss, x, z, killer})` (new): the normal-kill rule (alive, within 38 m), `DmLoot.roll_boss`, first kill per character
  (+2 shards, rare relic; `DmRewardsMember.trophies` / `trophy_store`), relic rune, XP, ground gold/shards/gear (gear rolled by the member's api), and a
  `reporter.boss({boss, tier, diff, first})` entry that rides the next `session_report`. The Empowered claim (Covenant Seal) is not ported.
* **Audio**: `bossAwaken`/`bossDefeat` sounds go through the router, which makes the AudioDirector start/stop the war-drum bed; `AudioDirector.set_boss_music` follows the
  local hero (alive, in the boss area, a boss awake), checked at 2 Hz.

## Gravedigger King, as reproduced (numbers = `content/bosses.json`, level/difficulty scaled like the current game)
HP 22,000 x (1 + 0.22 (L-1)) x party (1 + 0.8 (n-1)) x difficulty. Arena (-14,-22) r 10, leash r-2. Spade Sweep: cone r 4.5 / 50 deg half-angle, 900 ms, 18 dmg, cd 3.4 s
(first at 2.5 s). Burial: grave outline 0.6 x 1.2 on the 2 nearest players (all players in P3), 1,400 ms, 12 dmg, root 2 s, cd 7 s (first at 4 s). P2 (60 %): Exhumation, 2 Barrow
Ghouls on the rim every 14 s (first 4 s in), cooldowns x0.88, faster walk; elite Grave Robber at 45 %. P3 (30 %): four open pits r 1.2 (walking in = 0.6 x 12 dmg + root 2 s, re-bury cd 3 s),
cooldowns x0.75, a second sweep +60 deg 650 ms after the first. Wipe/leave = reset (no reward). Adds spawned through the wave director (they pay as normal kills; they vanish on a reset).

## Seams touched in shared code (all backward compatible)
`DmNextGame`: child `bosses`; `enemies_in_radius` / `enemy_by_id` include living bosses (dm_id >= `DmBossHost.ID_BASE`); `DmNextInput._pick_enemy` includes bosses.
`DmWaveDirector.spawn` returns the new id. `DmEnemyFx` skips `DmBoss`. `DmThrall`: bosses count from their edge (`_edge`) in the engage range and the owner leash (the boss-engage rule).
`DmHeroBody.root_for(s)` + the mover honours `rootedUntil`. `DmNextHudVm`: `boss` (the HUD boss bar: name, phase title, hp) and the minimap boss dot. `DmSessionRewards.on_boss_defeated`, `DmRewardsMember.trophies/claim_trophy`.

## Recipe: the next boss (abbess, congregation, prelate, saint, regent, mire)
1. **Nothing to rewrite for the brain**: `DmBossBrains.make(world, id)` already builds it. Add `"<id>"` to `DmBossHost` areas: the host serves one `area_id` today (set it per area, or
   give the host an `area_id` per boss); the summon site comes from the area's `summonId` interactable, the model/colour from `bosses.json` (DmBossView already supports all seven looks).
2. **World hooks the brain calls** (`dm_boss_node_world.gd`; stubs return empty/no-op now):
   * `corpses()` / `remove_corpse(id, reason)` (Abbess devours, Mire raises): map to `game.corpses` (`corpses_in_radius`, `consume`).
   * `cover()` (Congregation pews): the world builder's pew prop boxes.
   * `hostile_toxic_zones()` / `add_hostile_pool` / `ember_pool` (Saint rot pools, Regent coals): `DmHostileZone.spawn` (host-damaging, visual-only copies come from the event fx).
   * `echoes()` (Prelate vow echoes): the progression's vow state.
   * Niches/adds the brain spawns through `spawn_enemy` already work (director); a def that has no `res://enemies/<id>.tscn` yet needs its kind scene (enemy-kinds track).
3. **Hittability**: the Mire Mother is untouchable while `state == "sunk"`: extend `DmBoss.is_hittable()` with the brain state. Prelate summons by `spend_shards` (bell), not `spend_boss_shards`.
4. **Presentation is free** if the id exists in `bosses.json`: view clip choices (`DmBossView` match on state), the router's `DmEventFxBoss` kinds (lance, chorus, hymn, rotRain, coals, conflagration, surface, flood ...).
   Only add a `warm()` shape for a kind whose first draw hitches.
5. **Tests**: copy `tests/next_bosses/run.gd` parts A/B: summon refusals, each attack's event (`brain_event`, ms and numbers from the content file), phase thresholds, adds, defeat -> reward + reporter entry, 2-peer replication.

## Late bosses: Plague Saint (cloister), Cinder Regent (pyre), Mire Mother (fen)
Suites: `tests/next_bosses/saint_run.gd`, `regent_run.gd`, `mire_run.gd` (shared helpers in `late_base.gd`). Pictures: `shot_late.gd` (the slice) vs `shot_ref.gd` (the current client's harness, same events).
* **Host**: serves `served_areas` (graves, cloister, pyre, fen; each boss's own `DmContent.boss(id).area` is its arena, the host is no longer tied to one `area_id`). `DmBossHost.area_at` answers
  `world.area_at` (or `assume_area` headless), so adds / corpses are matched to the boss's area. `active_boss()` = awake (even if sunk), `living()` = awake AND hittable.
* **Hooks (dm_boss_node_world.gd)**: `corpses()` / `remove_corpse` -> `DmCorpseField` (echoes excluded; `consume(id, 0, "raised")`), `hostile_toxic_zones()` -> every live damaging toxic `DmHostileZone`
  (cached per frame / zone count), `add_hostile_pool` / `ember_pool` -> `DmBossHost.spawn_pool`: a host-damaging `DmHostileZone` (credited to the boss; `dm_take_enemy_hit` hits heroes AND thralls) under the host's `Pools` node,
  announced by a reliable rpc so every other peer holds a visual-only copy (`damaging = false`). Toxic pools are drawn by `DmBossFx.pool_visual` (the current zone look); ember pools by the
  `DmEnemyFx` zone watcher like the pyre's other embers.
* **Hittability**: `DmBoss.is_awake()` / `is_hittable()` (false while `bstate.state == "sunk"`, replicated): rites, thralls (retarget), the hover pick and `enemies_in_radius` skip a sunk Mire Mother; the brain refuses damage too.
* **Hands** (Mire) root like Burial: `_route` treats `hands` impacts as `bury`. Defeat timer is a child Timer of the body (the old SceneTreeTimer lambda called a freed boss).

## Gaps
Empowered (Covenant Seal) summons and the seal prize; first-kill trophies are in memory per session unless
the shell sets `trophy_store`; chronicle/codex entries; boss slow/root statuses are ignored (the brain owns speed); hitstop callback unset in the slice; the Prelate/Sanctum has no area in the slice yet. A late joiner does not see pools that are already burning (the rpc is at creation); the flood's hummock shrink is a presentation event the world builder does not ease yet; the pools of a boss that resets linger their remaining seconds (as sim zones did). Thralls/adds in the three new areas path only where the areas track has baked navigation.


## Cost (headless, shared VPS)
Brain tick median ~45-60 us with 20 adds + 6 thralls alive (budget 400 us); a telegraph's fx ~90 us/event; state 20 Hz only with peers (one packet). `warm()` loads the area's boss models and draws one sweep + bury silently at load.
