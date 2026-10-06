# godot/next/feel: the necromancer's combat feel

Local-owner input logic (`dm_combat_input.gd`, `DmCombatInput`, owned by `DmNextInput.combat`) plus, elsewhere: gestures (`next/rites/dm_rite_gestures.gd`),
hitstop (`DmNextGame.hitstopper`), runes (`DmNextGame.rune_sockets / sync_runes`). All input is an ordinary intent (`request_move_to`, the hotbar seam), so it works online unchanged.

| feel | how |
|---|---|
| click an enemy | `DmNextInput.attack(id, shift)`: attack target; the first step is taken in the click, then `tick` each physics frame: out of the primary's range (`DmAbilities.shortfall`, the host's own check) = walk (one `request_move_to`, re-planned only when the enemy moved >= 1 m), in range = stop + cast the primary whenever `cooldown_left` is 0. The target is sticky (hold = repeat, cadence = the rite's cooldown) until it dies, WASD or a ground click |
| Shift + click | cast in place, never walks; holding Shift during a chase stops it; Shift on the ground just stands |
| queued cast | a deliberate key / RMB cast refused `busy`, or `cooldown` with <= 220 ms left, waits 220 ms and is retried every 50 ms (`DmGameInput.queued_cast`); other refusals drop it |
| held number keys | repeat once held 150 ms and the rite is ready (only slots 1-5, like the old client) |
| gesture | host `_apply_cast` -> `_gesture_cast` after a successful resolve: its own RPC (not an event), `avatar.cast(kind, seconds, yaw, gestureSeconds, ability)` once per accepted cast on every peer, same table as `DmAbilitySystem._gesture` |
| hitstop | `DmHitStop` (min gap, leaky budget) fed by `enemy_fx` / `bosses.fx` (`host.hitstop_cb`: heavy hits, elite deaths, boss impacts); drives `Vfx.hitstop_scale` and `DmCreature.hitstop_scale` (picture only); off under `reduce_motion` |
| shake | each owner's caster `shake_requested` -> `camera.shake` (honours `reduce_motion`) |
| runes | `rite_build()["runes"] = rune_sockets(peer)` = `DmRunes.sockets_of(bag)` for the local host (necromancer); `sync_runes()` on every bag change -> `DmRiteCaster.set_runes` |

Cost: `tick` returns on its first line when there is no target / queue / held key (0.4-0.9 us); with a target ~30-40 us, no allocations. Tests: `tests/next_feel/run.gd`.

Not done: Easy auto-combat (`DmAutoCombat.select_action/select_movement` read the old sim's enemy / corpse records, so it needs an adapter over the nodes world and the settings' `auto_combat_allowed` gate);
standing mouse-aim facing (`aim_when_standing`); the old scythe `attack` gesture (no rite module); remote peers' runes (only the local host's bag is known until the join handshake carries one).
