# godot/next/rites: Gravecaller rites on the session structure

`DmRiteCaster` (`dm_rite_caster.gd`) is a Node that is a child of every player body on every peer, named `Rites`
(`DmRiteCaster.attach(body, world)`; same NodePath on every peer, because RPCs resolve by path). The caster is the shared plumbing (intent RPC,
owner / cooldown / essence validation through DmAbilities, event broadcast, once-per-peer playback, state replication); **each rite is its own
module** `rite_<id>.gd` (a `DmRiteModule`) listed in `dm_rite_registry.gd` (one line per rite). Ported so far:

| rite | slot | why |
|---|---|---|
| `bone_needle` | LMB primary | the Gravecaller's primary attack; targeting `enemy`, 380 ms, free, +6 essence per hit, range 11, projectile 26 m/s |
| `miasma` | rite 1 | the grimoire's area rite. Ground-targeted, 25 essence, 7 s, radius 3.8 x mods, a 6 s Withered cloud (+1 stack per second, slow 0.6) |

| `exhume` | slot 2 | raise the corpse under the cursor via `DmThrallHost.raise` (consumes through `DmCorpseField`); Mass Grave / Bone Colossus runes. 12 essence, 500 ms |
| `black_litany` | slot 4 | consume corpses + sacrifice thralls within 7 m: damage = spell power x `litany_mult`, barrier + heal paid ONCE on the host from the burst's counts; Hollow Choir (spare) and Requiem (delay, wider) runes. 40 essence, 14 s |
| `corpse_explosion` | RMB | detonate the corpse under the cursor (r 3, resonant x1.6, elite x2, toxic leaves a Miasma-rules rot pool). 15 essence, 600 ms |
| `grave_offering` | (no default slot) | burn a corpse into essence (16, +8 resonant, x2 elite) and 4 % health via an orb (14 m/s). Free, 2 s, level 2 |
| `bone_mantle` | (no default slot) | up to 5 corpses within 6 m -> barrier maxHp x min(0.45, 0.10 + 0.07 n) for 6 s, shards every 0.5 s within 1.7 m. 25 essence, 15 s, level 12 |
| `carrion_seed` | (no default slot) | arm a corpse (arm 0.6 s, life 20 s, trigger 2.2 m); it bursts r 3 with 2 Withered stacks; one seed per caster. 18 essence, 6 s, level 8 |

Hotbar mapping (the one place to take over): `dm_rite_hotbar.gd` (`DmRiteHotbar.rite_for_slot`, `wire(game)`): LMB = kit `defaultPrimary`, 1-4 = kit
`defaultLoadout` (marrow_spear has no module yet: refused `unavailable`), RMB = kit `rmb`. `shake_requested(amount)` is the camera-shake seam.
World additions for the corpse rites: `world.corpses` (the `DmCorpseField`) and `world.area_of(peer)`; the thralls come from the body's `Thralls` host.

All numbers come from the existing rules (`DmAbilities.cast_check / needle_cast / needle_hit / miasma / apply_cast_cost / shortfall`,
`DmSimData.WITHERED / MIASMA_SLOW`, projectile speeds from `sim_caster.gd`). No new numbers except `PICK_RADIUS` (aim-point tolerance).

## Adding a rite (the recipe)

1. `godot/next/rites/rite_<id>.gd`: `extends DmRiteModule`, `func _init(): id = "<id>"` (and `steps = true` if it ticks on the host). Modules are shared
   singletons: keep per-caster state in `c.mem(id)` (a Dictionary), never in fields.
2. Override what you need (all get the `DmRiteCaster c`):
   - `validate(c, intent) -> String` HOST, before anything is spent. `""` = go, else a refusal reason (`no_target range no_corpse ...`). Free to the
     caster. `intent = {rite, aim, target_id, sender}`; stash what you found (`intent["foe"] = ...`). The shared checks (owner, finite aim, registered,
     DmAbilities.cast_check: dead / locked / busy / cooldown / essence) already ran.
   - `resolve(c, intent) -> String` HOST, cost paid and cooldown running (`DmAbilities.apply_cast_cost`). Roll numbers with DmAbilities / DmSimData, delay
     with `c.after(ms, fn)`, damage with `DmStatusSet.hit(target, amount, c.body)` / `DmEnemy.take_damage`, statuses with `DmStatusSet.ensure(e).apply`,
     corpses only through the field's atomic `consume`, then `c.broadcast({"t": ..., "rite": id, ...})`. Return `""`, or a reason when it could not
     happen (the cost and cooldown are refunded and the owner gets `cast_rejected`).
   - `play(c, ev)` EVERY peer, once per event: visuals through `c.fx` (`DmRiteFx`, extract shared helpers there rather than copying), floating numbers
     through `c.hit_number`. Only the event dictionary is available (clients hold no host state), so put everything the visuals need in the event.
   - `step(c, dt)` HOST per physics tick (zones, armed seeds, tethers) while `steps` and `c.mem(id)` exists.
3. One line in `dm_rite_registry.gd`: `"<id>": preload("res://next/rites/rite_<id>.gd"),`. Run `godot --headless --path godot --import` once.
4. Add checks to `godot/tests/rites/` (validation + refusal, numbers vs DmAbilities, fx once per peer; see the per-rite suites).
Caster API for modules: `c.p` (host state: essence, cooldowns, stats, loadout), `c.mods`, `c.now_ms`, `c.body`, `c.world`, `c.peer_id`, `c.fx`, `c.rand()`,
`c.mem(id)`, `c.after()`, `c.tip()`, `c.broadcast()`, `c.push_state()`, `c.gain_essence()`, `c.add_barrier()`, `c.set_mantle_barrier(n)`, `c.heal()`,
`c.watch_dots(ss)`, signals `hit_resolved` (host, kill credit) / `hit_number` (every peer). Unregistered rites a client asks for locally are refused
`unavailable`; a forged unknown rite at the host counts as `rejected_intents`.

## Flow (REBUILD D1)

1. Owner: `request_cast(rite, aim: Vector3, target_id := -1)` -> `_rpc_cast` (any_peer, reliable) to the host. No client prediction.
2. Host `_apply_cast` (`module.validate` then cost then `module.resolve`): sender must be the body's owner (else `rejected_intents++`, nothing happens), finite aim, known rite; then
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

Input: the slice's hotbar signal is mapped by `DmRiteHotbar` (above). If the InputMap has `rite_primary` and `world.aim_point()` exists, the owner's caster
also polls it (hold = repeat, the host's cooldown paces it). Otherwise the shell just calls `request_cast`.

## Integration notes

- Add a caster to EVERY body on EVERY peer, with the same name, as soon as the body spawns (`Players.child_entered_tree`, deferred, is what
  the tests do). Events that arrive before a peer has attached are dropped by Godot (reliable RPC to a missing path errors once).
- Enemies must exist on the host; `DmEnemy` authority is the host. The host steps the caster in `_physics_process` (`auto_step`).
- Bodies need `owner_peer` (DmSessionBody has it) and sit in the same SceneTree as the enemies so `global_position` agree.
- The cloud applies `slow` and `withered` through `DmStatusSet` (`next/status/`, ensured on each enemy it touches); the set owns `DmEnemy.speed_mult`. Deterministic hosts must also `advance(dt)` the enemies' sets (tests/rites does).
