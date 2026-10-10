# DmEnemyFx: enemy telegraphs, strikes, deaths and voices

One node per peer. Host, clients and solo all run the same code; it only reads each peer's own `DmEnemy` nodes.

```gdscript
var fx := DmEnemyFx.new()
fx.player_pos = func() -> Vector3: return local_hero.global_position   # distance gating; default = camera position
fx.host.hitstop_cb = hitstop_callable          # (seconds) for heavy hits / elite deaths near the hero
fx.host.camera = camera_rig                    # optional, anything with shake(amount)
fx.host.dressing = water_surface               # optional, add_ripple(x, z, size)
add_child(fx)                                  # autowatches every DmEnemy and DmHostileZone added to the tree afterwards (and existing ones)
```
`Vfx` and `AudioDirector` autoloads are used unless `fx.set_backends(vfx, audio)` is called (tests). `fx.scope = node` restricts it to a subtree.
Never create two per peer watching the same bodies (everything would play twice).

## Shell entry point (done in `next_game.gd`)
`DmNextGame.enemy_fx` (child `EnemyFx`, every peer) is created in `start()` before the director: `player_pos` = local body, `host.camera` = the camera rig,
`auto_watch = false` (no `node_added` callback for every node in the tree), `watch(e)` called from the `enemy_spawned` hook, `watch_zones_under(node)` on the enemy holder and the boss pool node (`DmBossHost.pools_created`) for dust / ember clouds, and `enemy_fx.warm(local_body position)` at the end of
`start()` (visual runs): silent one-of-each telegraph / burst / censer effect so pools, textures and shaders exist before the first fight.
`host.hitstop_cb` is wired by `DmNextGame` to `hitstopper` (`DmHitStop`, picture-only: no `Engine.time_scale`, so online peers never desync; each peer freezes its own view).

## What a peer must do for it to work
- Instantiate puppets with the same `def_id`, `elite`, `rising`, `in_graves` as the host body (spawn args).
- Feed puppets `get_net_state()` / `apply_net_state()` snapshots (new keys: `aim`, `t` = seconds in state). Nothing else is replicated for fx.
- Host-spawned `DmHostileZone`s are visualised on the host; each client's fx spawns its own visual-only (`damaging=false`) cloud at the swing's impact time.

## Signals consumed (each peer, exactly once per event)
| signal | source | plays |
|---|---|---|
| `telegraph(kind, from, aim, radius, seconds)` | host: begin_attack / erupt; client: derived from the replicated ATTACK/ERUPT state via `DmEnemy.announce_telegraph` (remaining = windup - `t`) | cone / slam / dust / erupt ground shapes through `DmEventFxTelegraph` (same shape, timing, colour, sound `tollSmall`/`tellStrike`) inside `Vfx.danger()` |
| `state_changed` -> ATTACK | both | impact timer (windup left); cancelled by any state change (stun, death). At impact: attack voice (<=18 m, by family), smoke at the aim; sac slam puff + `boneHit`; moth dust ring burst + cloud |
| `state_changed` -> EMERGE / DIG | both | ghoul eruption burst (dirt, cracks, `burst`), dig-in smoke |
| `state_changed` -> DEAD | both | `DmEventFx._death`: `enemyDeath`/`eliteDeath`, death voice (<=26 m), elite hitstop, ripple, fire-death flare; smoke; elite purple burst + light; wraith defs thin to mist and sink |
| `damaged` | host: take_damage; client: hp drop in the snapshot | heavy-hit hitstop (same thresholds as DmEntityViews). Hit flash is `DmEnemy._flash` (now also set on puppets) |
| ready (rising) | both | spawn smoke + sparks + cracks decal; elite: `eliteAggro` (<40 m) and the purple ring (persistent, follows) |
| DmHostileZone added | both | dust cloud (`zone_visual`), killed when the node leaves |
| `telegraph` kinds `ember` / `hex` / `pulse` / `hook` (Cinder Pyre / Mourning Fen kinds) | both | the router's own shapes (ember coal lob + landing burst, hex sigil + beam, wisp ring + ripples, sexton chain line); the Slag Brute's molten slam is picked by lending the router a def stub for the synchronous call |
| `state_changed` -> ATTACK impact (all kinds) | both | `DmEnemy.on_impact_visual()` (non-authority peers spawn the visual-only ember pool), spark shower for husk / cinderhound / slag brute |
| `state_changed` -> DEAD, def `emberDeath` | both | the husk's ember burst (`DmEventFx._burst` ember) on top of the fire-death flare |
| DmHostileZone `ember` | both | burning-ground decals + bonfire (`zone_visual`), like the dust cloud |
`struck` is host-only and unused. `cue` is host-only too, but the cues that have a visual are replicated by `DmNextNet` (`CUES`: `shield_block`, `sanctify`, `unbind`; reliable, batched with the 20 Hz send, <= 16 per tick; a client re-emits them on its puppet) so every peer draws each once: Templar shield glance (spark + chime), Deacon / Seraph Sanctify thread + halo, Acolyte Unbind beam + sigil. The Acolyte's crimson reach ring is derived per peer in the 5 Hz pass (drawn while a thrall is inside `UNBIND.range`, thralls replicate), no event. Other cues (`flask slam scream hook erupt dig_in`) have no visual of their own: their telegraphs / states draw them. Two games in one test process: set `enemy_fx.scope` on each, or every fx watches both trees. Censer ring/smoke and haste motes belong to the status track (`DmStatusSet`), not duplicated here. Idle motes (rising dust, hover motes, tunnelling dirt, the pyre's ember shedding, the fen wisp's marsh light, the hag's drips, the sexton's water) run in one 5 Hz pass over watched enemies within 24x20 m of the hero, reusing scratch dictionaries.

## Replication / lead time
A telegraph is the state change to ATTACK/ERUPT, so it reaches a client with the next snapshot. Measured in-process over ENet loopback (tests/enemy_fx/run.gd):
snapshots at 20 Hz: delay 14-55 ms, so the client still has 664/700 ms (sac), 936/950 (moth), 1086/1100 (penitent), 945/1000 (ghoul eruption) to dodge;
with an immediate snapshot on `state_changed` (recommended for the session layer): 1-3 ms delay. Real latency adds on top; the telegraph's fill is shortened by `t` so it still lands with the blow. Budget at 20 Hz: <= 50 ms snapshot wait + one-way latency.

## Cost / warm-up
No new effects, textures or sounds: everything is existing Vfx decals/emitters/Binbun `censer_incense` and existing sound ids (`DmEnemyFx.EFFECT_IDS`, `SFX_IDS`, checked by the suite), so DmWarmup's all-effects pass covers it. Headless measurements (real Vfx, 30 enemies): ~27 us/frame idle; telegraph ~200 us/event; impact ~90 us; death ~150 us (incl. the enemy itself). Pools are Vfx's.

## Tests / known gaps
Suite: `tests/enemy_fx/run.gd`. `DmEnemyFxHost.dressing` (ripple surface) is not set by `DmNextGame`.

Elite affixes (next/affixes), toxic-stink on corpses and corpse looks (corpse track), per-kind idle fx of kinds that have no scene yet (fire/fen/etc. exist in the router: `fx._death` already handles fire deaths).
