# godot/next/rites: Gravecaller rites on the session structure

`DmRiteCaster` (`dm_rite_caster.gd`) is a Node that is a child of every player body on every peer, named `Rites`
(`DmRiteCaster.attach(body, world)`; same NodePath on every peer, because RPCs resolve by path). It casts two rites:

| rite | slot | why |
|---|---|---|
| `bone_needle` | LMB primary | the Gravecaller's primary attack; targeting `enemy`, 380 ms, free, +6 essence per hit, range 11, projectile 26 m/s |
| `miasma` | rite 1 | the kit's only area rite that needs nothing else: `exhume`, `black_litany` and `corpse_explosion` need corpses/thralls (a later system), `marrow_spear` is a line. Ground-targeted, 25 essence, 7 s, radius 3.8 x mods, a 6 s Withered cloud (+1 stack per second, slow 0.6) |

All numbers come from the existing rules (`DmAbilities.cast_check / needle_cast / needle_hit / miasma / apply_cast_cost / shortfall`,
`DmSimData.WITHERED / MIASMA_SLOW`, projectile speeds from `sim_caster.gd`). No new numbers except `PICK_RADIUS` (aim-point tolerance).

## Flow (REBUILD D1)

1. Owner: `request_cast(rite, aim: Vector3, target_id := -1)` -> `_rpc_cast` (any_peer, reliable) to the host. No client prediction.
2. Host `_apply_cast`: sender must be the body's owner (else `rejected_intents++`, nothing happens), finite aim, known rite; then
   `DmAbilities.cast_check` (dead / locked / busy / cooldown / essence), needle range (`DmAbilities.shortfall`) and target. A legit refusal goes
   back to the owner (`cast_rejected(rite, reason)`: `cooldown busy essence range no_target dead`). Miasma clamps the aim to its range like the
   current game.
3. Host spends essence and starts the cooldown (`apply_cast_cost`), schedules the shot (flight time = distance / speed), and broadcasts a
   `cast` event. On arrival it damages `DmEnemy.take_damage(amount, body)` (needle) or creates the cloud (miasma), then broadcasts `hit` / `land`.
   The cloud pulses Withered stacks on `DmEnemy`s in radius and burns them (in 0.25 s lumps via `take_damage(.., allow_stagger=false)`).
4. Every peer (the host included, also solo) plays each event exactly once via `DmRiteFx` (`godot/game/dm_rite_fx.gd`, shared with the
   current game's `DmAbilitySystem`) and emits `event_played`; `hit_number(pos, amount, crit)` is for the shell's floating numbers.
5. Resource/cooldowns live on the host. The owner gets `{essence, max_essence, cooldowns{id: remaining_ms}, alive}` by RPC (10 Hz while
   essence changes, immediately on cast/hit): `get_state()`, `state_changed`, `cooldown_left(rite)`.

Host-only hook: `hit_resolved(rite, enemy_id, amount, crit, killed)` for kill credit / the rewards track.
`set_alive(false)` on the host stops casting and any shots in flight.

## DmRiteWorld (duck-typed; set `caster.world` / pass to `attach`)

Required (host side; clients only need them for projectile follow-through, returning null/empty is fine):
- `enemies_in_radius(pos: Vector3, r: float) -> Array` of `DmEnemy`
- `enemy_by_id(id: int) -> Node` (null when gone)
- `enemy_id(enemy: Node) -> int` (stable, same meaning on the host's wire; DmEnemy has no id field of its own)

Optional:
- `rite_build(peer_id: int) -> Dictionary` `{stats, discipline:{family, mods}, loadout, runes}` (what `DmCharacterBuild.build` returns, plus
  `runes`); default: a level-1 Gravecaller (`class_index 0`).
- `aim_point() -> Vector3` and `aim_target_id() -> int` (owner input polling, see below)
- `on_rite_event(ev: Dictionary)` every event on every peer (camera shake, gestures: the current game does those in the avatar/camera).

Input: if the InputMap has `rite_primary` / `rite_1` and `world.aim_point()` exists, the owner's caster polls them (hold = repeat, the
host's cooldown paces it). Otherwise the shell just calls `request_cast`.

## Integration notes

- Add a caster to EVERY body on EVERY peer, with the same name, as soon as the body spawns (`Players.child_entered_tree`, deferred, is what
  the tests do). Events that arrive before a peer has attached are dropped by Godot (reliable RPC to a missing path errors once).
- Enemies must exist on the host; `DmEnemy` authority is the host. The host steps the caster in `_physics_process` (`auto_step`).
- Bodies need `owner_peer` (DmSessionBody has it) and sit in the same SceneTree as the enemies so `global_position` agree.
- The cloud applies `slow` and `withered` through `DmStatusSet` (`next/status/`, ensured on each enemy it touches); the set owns `DmEnemy.speed_mult`. Deterministic hosts must also `advance(dt)` the enemies' sets (tests/rites does).
