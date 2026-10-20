# DmEnemyFx: enemy telegraphs, strikes, deaths and voices

One node per peer (child `EnemyFx` of `DmNextGame`). Host, guests and solo run the same code, and it is driven by the signals of `DmCoreHost` (`bind`): the core's events, read once per tick (a guest's puppet core
raises the same events from the wire). No node, no script and no signal connection exists per creature; what it remembers per creature is a few numbers in dictionaries keyed by id, only while the creature
has something to play (a swing in its wind-up, a rise, a burrow, an elite's ring, a body with a status). The creatures themselves are drawn by the crowd (client/crowd/README.md).

```gdscript
var fx := DmEnemyFx.new()
fx.player_pos = func() -> Vector3: return local_hero.global_position   # distance gating; default = camera position
fx.host.hitstop_cb = hitstop_callable          # (seconds) for heavy hits / elite deaths near the hero
fx.host.camera = camera_rig                    # optional, anything with shake(amount)
fx.host.dressing = water_surface               # optional, add_ripple(x, z, size); no game scene sets it
add_child(fx)
fx.bind(core_host)                             # connects the core's signals; `watched()` counts what it holds, `clear()` lets it all go
```
`Vfx` and `AudioDirector` autoloads are used unless `fx.set_backends(vfx, audio)` is called (tests). Never create two per game (everything would play twice).

## Shell entry point (done in `client/next/next_game.gd`)
`DmNextGame.enemy_fx` is created in `start()` after the core host: `player_pos` = local body, `host.camera` = the camera rig, `host.hitstop_cb` = the game's `hitstop` (`DmHitStop`, picture-only: no `Engine.time_scale`, so
online peers never desync; each peer freezes its own view), then `bind(core_host)`; at the end of `start()` (visual runs) `enemy_fx.warm(local_body position)` plays a silent one-of-each telegraph / burst / censer effect so pools,
textures and shaders exist before the first fight.

## Signals consumed (each peer, exactly once per event)
| core signal | plays |
|---|---|
| `enemy_spawned` | the rise: spawn smoke + sparks + cracks decal; an elite: `eliteAggro` (< 40 m) and the purple ring (persistent, follows the drawn body); an affixed body's standing marks (the bell's ring, the hunger's glow, the shroud's haze, the vengeful cracks) |
| `telegraph(kind, from, aim, radius, seconds)` | the ground shapes (cone, slam, dust, erupt, raise, curse, scream, dive, ember, hex, pulse, hook, flask) through the router's telegraph module (`client/game/dm_event_fx_telegraph.gd`: same shape, timing, colour, sound `tollSmall` / `tellStrike`) inside `Vfx.danger()`. On a guest it is derived from the snapshot's ATTACK edge (native/README.md "Co-op: snapshots, events and the puppet core") |
| `enemy_attack` | the impact timer (the wind-up comes with the event), cancelled by any state change (stun, death, removal). At impact: the attack voice (<= 18 m, by family), smoke at the aim; the sac's slam puff + `boneHit`; the moth's dust ring burst + cloud; sparks for the husk, cinderhound and slag brute |
| `enemy_state` | the ghoul's eruption (dirt, cracks, `burst`), dig-in smoke, the dirt mound over a body underground |
| `enemy_died`, `enemy_removed` | `DmEventFx._death`: `enemyDeath` / `eliteDeath`, the death voice (<= 26 m), elite hitstop, ripple, fire-death flare, smoke, the elite's purple burst + light, the wraith thins to mist; the husk's last embers. A body removed alive swings no more |
| `enemy_damaged` | the heavy-hit hitstop (a hit of 22 % of max health, 12 % for an elite, within 16 m). The hit flash is the crowd's |
| `cue` | the cues that have a visual: the Templar's shield glance (spark + chime), Deacon / Seraph Sanctify (thread + halo), Acolyte Unbind (beam + sigil). Cues that are only a sound or a telegraph (`flask`, `slam`, `scream`, `hook`, `erupt`, `dig_in`) draw through their telegraphs and states |
| `zone`, `zone_gone` | the dust cloud, the burning ground (decals + bonfire) and every toxic pool that has a source (a boss's rot, the Plague Doctor's flask pool: cracked green ground, the enemy toxic colours), up while the zone stands and ended by `zone_gone`; a burst corpse's pool (no source) is the corpse mark's green disc |
| `affix_moment` | the elite beats `tell`, `toll`, `hungering`, `vengeful`, `unveil` |
| `status_changed`, `statuses_cleared` | which bodies the ambient pass looks at for status tells |
| `thrall_raised`, `thrall_died`, `thrall_removed` | `thrallRise`, `thrallDeath` (killed ones only), every thrall's ground ring (champion gold, an ally's dimmer; the plague bearer's and the colossus' larger) |
| `corpse_added`, `corpse_gone`, `corpse_consumed` | a faint pale ring under every fresh corpse for its 26 s (at most 8 at once), a violet one under a resonant corpse, a green disc under a toxic one for 5 s; the puff for why a corpse went |

Which sound each of these plays: client/README.md "Sound". The shrouded body's fade and an elite's body glow are the crowd's (client/crowd/README.md "The alpha path"), not this node's.
One ambient pass at 5 Hz (`AMBIENT_S`) over the bodies within 24 x 20 m of the hero, reading their places from one read of the core's bulk arrays: idle motes (rising dust, hover motes, tunnelling dirt, the Pyre's ember shedding, the Fen wisp's marsh light,
the hag's drips, the sexton's water), the status tells (marrow drips while bleeding, frost motes while chilled, a priest-gold glint while sanctified, rot while withered, bone dust while fractured, bronze motes while incensed, blood motes while frenzied)
and the affixes' motes (drool, embers, shroud smoke while the shroud is up).

## Replication / lead time
A guest's telegraph is derived from the snapshot's ATTACK edge: its place and aim are the snapshot's and its seconds are the wind-up less the age the snapshot showed, so the fill still lands with the blow. Snapshots come at 20 Hz: the budget is
<= 50 ms of snapshot wait + one-way latency (native/README.md "Co-op: snapshots, events and the puppet core", "What a guest sees"). Cues, zones and affix moments travel as the core's reliable events.

## Cost / warm-up
No new effects, textures or sounds: everything is existing Vfx decals/emitters/Binbun scenes and existing sound ids (`DmEnemyFx.EFFECT_IDS`, `SFX_IDS`), so `DmWarmup`'s all-effects pass covers it. Pools are Vfx's.
Costs on the VPS in a Full Party frame are in client/README.md "The effects".

## Tests
`client/tests/enemy_fx/run.gd` (the flask pool drawn for its life, a boss's pools ended at once by `remove_zones_of`), `client/tests/game_scene.gd` (deaths, rises, swings' impacts, corpse marks and dust, nothing held after a death or removal), `client/tests/world.gd` (the later kinds' effects: the acolyte's reach ring, the flask's ring and landing, status motes) and
`client/tests/sound.gd` (the cues by name and count).

## Known gaps
- The water's ripples: `DmEnemyFxHost.dressing` is not set by any game scene (KNOWN-GAPS "Built but never shown"). 
