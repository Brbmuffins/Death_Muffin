# godot/next/bosses: the boss framework + all seven bosses (Gravedigger King, Bone Abbess, Drowned Congregation, Bell-Sworn Prelate, Plague Saint, Cinder Regent, Mire Mother)

Suites (`godot --headless --path godot --script res://tests/next_bosses/<x>.gd`): `run.gd` (framework + King), `abbess_run.gd`, `congregation_run.gd`, `prelate_run.gd` (all on the shared base `suite.gd`).
Screenshots: `shot.gd` (King), `shot_cathedral.gd --boss=abbess|congregation|prelate` (header has the render-lock command; `--probe=1` times the first draw of every event kind).

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
* **Summon** (`DmBossHost.try_summon(peer, id) -> why`; any peer asks through `request_summon`: key E near the site or a click on it): `DmBossHost.LIVE` lists the bosses this build wakes
  (each in its own area, whichever areas the world has open). Hero alive, within 4 m of the area's `summonId` interactable, no other boss awake, the member's
  `prog.spend_boss_shards(id)` (King 2, Abbess 3, Congregation 4); the Prelate takes the bell's `prog.spend_shards(5)` (which owes the run a Prelate summon). Refusals: `busy far shards dead unknown`.
  The prompt is the Chapterhouse hub's (`DmChapterhouse._update_prompt`): `<kbd>E</kbd> Summon X · N shards` within 5 m of a live site, the click prompt on hover, both hidden while a boss is awake (no toast).
* **Rewards**: `DmSessionRewards.on_boss_defeated({boss, x, z, killer})` (new): the normal-kill rule (alive, within 38 m), `DmLoot.roll_boss`, first kill per character
  (+2 shards, rare relic; `DmRewardsMember.trophies` / `trophy_store`), relic rune, XP, ground gold/shards/gear (gear rolled by the member's api), and a
  `reporter.boss({boss, tier, diff, first})` entry that rides the next `session_report`. The Prelate has no first-kill trophy: it is the run's boss (`prog.record_prelate_kill()`:
  tally + settles the bell's owed summon; the host tells the HUD `can_ascend`). The Empowered claim (Covenant Seal) is not ported.
* **Audio**: `bossAwaken`/`bossDefeat` sounds go through the router, which makes the AudioDirector start/stop the war-drum bed; `AudioDirector.set_boss_music` follows the
  local hero (alive, in the boss area, a boss awake), checked at 2 Hz.

## Gravedigger King, as reproduced (numbers = `content/bosses.json`, level/difficulty scaled like the current game)
HP 22,000 x (1 + 0.22 (L-1)) x party (1 + 0.8 (n-1)) x difficulty. Arena (-14,-22) r 10, leash r-2. Spade Sweep: cone r 4.5 / 50 deg half-angle, 900 ms, 18 dmg, cd 3.4 s
(first at 2.5 s). Burial: grave outline 0.6 x 1.2 on the 2 nearest players (all players in P3), 1,400 ms, 12 dmg, root 2 s, cd 7 s (first at 4 s). P2 (60 %): Exhumation, 2 Barrow
Ghouls on the rim every 14 s (first 4 s in), cooldowns x0.88, faster walk; elite Grave Robber at 45 %. P3 (30 %): four open pits r 1.2 (walking in = 0.6 x 12 dmg + root 2 s, re-bury cd 3 s),
cooldowns x0.75, a second sweep +60 deg 650 ms after the first. Wipe/leave = reset (no reward). Adds spawned through the wave director (they pay as normal kills; they vanish on a reset).

## Abbess, Congregation, Prelate, as reproduced (numbers = `content/bosses.json`; the brains are the sim's, only the world hooks and the adds are new)
* **Bone Abbess** (area ossuary, arena (48,-24) r 10, 3 shards, HP 17,000): four **Skull Niches** are director enemies of the new `niche` kind (`enemies/niche.tscn`,
  `DmEnemyNiche`: inert, label states, 7 % of her hp, model `skull_niche`; the rise plays, a break hides the body and the `nicheBreak` fx is the burst). A broken niche tears 4 % hp +
  a Fracture stack; while any stands she regenerates 0.25 %/s and a niche fires a Bone Lance every 8 s (1200 ms, 11 m line, 20 dmg); Ossuary Chorus 8 spokes / 9 m / 1200 ms / 22 dmg
  every 9 s, doubled +22.5 deg 900 ms later from P2; Grasp cone 700 ms / 18 dmg; P3 rebuilds two niches once and channels Bone Communion (4 s, devours every corpse of the arena, 1 %
  hp each). **Hook: corpses** = the real `DmCorpseField` (`corpses()` serves its non-echo records with their `area`; `remove_corpse` = `consume(id, 0, "devoured")`). Adds are spawned through
  `DmWaveDirector.spawn(..., area)` so a corpse made by an Ossuary kill is tagged `ossuary`. Niches leave with her (defeat / reset): no kill credit, no corpse.
* **Drowned Congregation** (nave, (0,-61) r 11, 4 shards, HP 19,000): Maul 800 ms / 18; Drowning Grasp 3-5 rings (one under every hero first) 1300 ms / 14 + root 1 s (any ms-0 event with `root`
  now roots the hero, not only the King's Burial); Flood Hymn 120 deg / 15 m / 2200 ms, 18 x 1.8, chills (the hurt event's `chillMs` now chills, as the pf casters do), x1.2 for whoever is off the
  dais in P3, and **pews are cover** (hook `cover()` = the sim world's four boxes `DmDb.sim_world()["cover"]`, for heroes and thralls); each phase six climbers (4 Choir Wraiths + 2 Penitents).
  The rising water (old client rule): from P2 wading off the 3.2 m dais is slower x0.85 / x0.7 (`DmBossHost._wade` -> `DmHeroBody.wade_mult`, host, 10 Hz, only while she is awake).
* **Bell-Sworn Prelate** (sanctum, (0,-116) r 13, bell = 5 shards through `spend_shards`, HP 26,000): Toll 6.5 m / 1500 ms / 24 every 9 s, Slam 2.6 m ahead / 900 ms / 20 every 3.2 s, Bell Rain from
  P2 (1400 ms, r 2.3, a circle on every hero + 2 / 4 in the arena, 18), Procession each phase (4 / 6 walkers, Risen + Penitents from the aisles), cooldowns x0.82 / x0.62, Toll and Slam x0.8 windup in P3.
  **Hook: echoes** = the summoner's vow `prelate_echo` (`member.prog.vow_fx().echoes`): I a second bell (3.6 m, on the farthest hero), II a longer Procession (+2) whose first two are elite, III a chasing
  volley 1.6 s after each Rain. Wake it from `DmContent.boss("prelate")`'s `sundered_bell`; defeat pays via `on_boss_defeated` as above.
* Areas: the slice only opens the Chapterhouse + Hollow Graves; these three are area-agnostic (the brain reads each hero's area string, the arena comes from content). The suites teleport into the real
  arenas (the world builder has every area's rect) and, for thralls, open the area's navmesh with `builder.set_unlocked([area])`, which is what a broken seal does.

## Seams touched in shared code (all backward compatible)
`DmNextGame`: child `bosses`; `enemies_in_radius` / `enemy_by_id` include living bosses (dm_id >= `DmBossHost.ID_BASE`); `DmNextInput._pick_enemy` includes bosses.
`DmWaveDirector.spawn` returns the new id and takes the area the add belongs to (level scaling, `dm_area`). `DmEnemyFx` skips `DmBoss`. `DmThrall`: bosses count from their edge (`_edge`) in the engage range and the owner leash (the boss-engage rule).
`DmHeroBody.root_for(s)` + the mover honours `rootedUntil`, `DmHeroBody.wade_mult` (x the move speed). `DmNextHudVm`: `boss` (the HUD boss bar: name, phase title, hp) and the minimap boss dot. `DmSessionRewards.on_boss_defeated`, `DmRewardsMember.trophies/claim_trophy`.

## Recipe: the next boss (saint, regent, mire)
1. **Nothing to rewrite for the brain**: `DmBossBrains.make(world, id)` already builds it. Add `"<id>"` to `DmBossHost.LIVE` (one line; `ADDS` for the defs its brain spawns, so `warm()` loads them);
   the summon site comes from the area's `summonId` interactable, the model/colour from `bosses.json` (DmBossView supports all seven looks).
2. **World hooks the brain calls** (`dm_boss_node_world.gd`): done: `corpses()` / `remove_corpse` (Abbess), `cover()` (Congregation), `echoes()` (Prelate). Still stubs: `hostile_toxic_zones()` / `add_hostile_pool` /
   `ember_pool` (Saint rot pools, Regent coals): `DmHostileZone.spawn` (host-damaging, visual-only copies come from the event fx); the Mire Mother's raise = `remove_corpse(id, "raised")`.
3. **Hittability**: the Mire Mother is untouchable while `state == "sunk"`: extend `DmBoss.is_hittable()` with the brain state. An add that has no `res://enemies/<id>.tscn` needs its kind scene (see `niche.tscn`).
4. **Presentation is free** if the id exists in `bosses.json`; only add a `WARM_KINDS` entry (`dm_boss_fx.gd`) for a kind whose first draw hitches (`shot_cathedral.gd --probe=1` times them).
5. **Tests**: `class extends "res://tests/next_bosses/suite.gd"`, implement `_parts()` (see `abbess_run.gd`): `check_prompt_and_key`, `check_summon_rules`, `check_defeat`, `check_thralls_and_rites`, `check_wipe`, `check_perf`, `two_peers_*`.

## Late bosses: Plague Saint (cloister), Cinder Regent (pyre), Mire Mother (fen)
Suites: `tests/next_bosses/saint_run.gd`, `regent_run.gd`, `mire_run.gd` (shared helpers in `late_base.gd`). Pictures: `shot_late.gd` (the slice) vs `shot_ref.gd` (the current client's harness, same events).
* **Host**: serves `served_areas` (graves, cloister, pyre, fen; each boss's own `DmContent.boss(id).area` is its arena, the host is no longer tied to one `area_id`). `DmBossHost.area_at` answers
  `world.area_at` (or `assume_area` headless), so adds / corpses are matched to the boss's area. `active_boss()` = awake (even if sunk), `living()` = awake AND hittable.
* **Hooks (dm_boss_node_world.gd)**: `corpses()` / `remove_corpse` -> `DmCorpseField` (echoes excluded; `consume(id, 0, "raised")`), `hostile_toxic_zones()` -> every live damaging toxic `DmHostileZone`
  (cached per frame / zone count), `add_hostile_pool` / `ember_pool` -> `DmBossHost.spawn_pool`: a host-damaging `DmHostileZone` (credited to the boss; `dm_take_enemy_hit` hits heroes AND thralls) under the host's `Pools` node,
  announced by a reliable rpc so every other peer holds a visual-only copy (`damaging = false`). Toxic pools are drawn by `DmBossFx.pool_visual` (the current zone look); ember pools by the
  `DmEnemyFx` zone watcher like the pyre's other embers.
* **Hittability**: `DmBoss.is_awake()` / `is_hittable()` (false while `bstate.state == "sunk"`, replicated): rites, thralls (retarget), the hover pick and `enemies_in_radius` skip a sunk Mire Mother; the brain refuses damage too.
* **Hands** (Mire) root like Burial: `_route` roots on any ms-0 event carrying `root` (bury, hands, the Congregation's grasp). Defeat timer is a child Timer of the body (the old SceneTreeTimer lambda called a freed boss).

## Gaps
Empowered (Covenant Seal) summons and the seal prize; first-kill trophies are in memory per session unless
the shell sets `trophy_store`; chronicle/codex entries; boss slow/root statuses are ignored (the brain owns speed); hitstop callback unset in the slice; the Ossuary / Nave / Sanctum are not open in the slice yet (their
bosses run in them as soon as the areas track opens them; thralls need the area's navmesh); the Prelate's tally is validated by the backend only for a bell it was told of (online `spend_shards` queues `summon_prelate`);
`can_ascend` is emitted as a game event only; a late joiner does not see pools that are already burning (the rpc is at creation); the flood's hummock shrink is a presentation event the world builder does not ease yet; the pools of a boss that resets linger their remaining seconds (as sim zones did); the first draw of the six-walker Procession spawn costs one slow frame under software GL (not measured on a GPU).


## Cost (headless, shared VPS)
Brain tick median ~45-60 us with 20 adds + 6 thralls alive (budget 400 us); a telegraph's fx ~90 us/event; state 20 Hz only with peers (one packet). `warm()` loads the live bosses' models and their adds' scenes/models (~5 ms headless) and draws `WARM_KINDS` silently at load (no sound, no banner).
Per boss (headless, `check_perf`): brain tick median 30-70 us (budget 400 us) with 4 niches / 6 climbers / 12 walkers; whole frame with the boss ticking vs not: +0.0-0.2 ms (budget 2 ms), worst frame < 12 ms (cap 150).
