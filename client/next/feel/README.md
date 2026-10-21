# client/next/feel: the necromancer's combat feel

Local-owner input logic (`dm_combat_input.gd`, `DmCombatInput`, owned by `DmNextInput.combat`) plus, elsewhere: gestures (`client/next/rites/dm_rite_gestures.gd`),
hitstop (`DmNextGame.hitstopper`), runes (`DmNextGame.rune_sockets / sync_runes`). All input is an ordinary intent (`request_move_to`, the hotbar seam), so it works online unchanged.
An enemy is the core's id: the attack target is an id, and its place and whether it can be hurt come from the caster's `foe` snapshot (a boss is a target like any enemy; its radius counts in the primary's range).

| feel | how |
|---|---|
| click an enemy | `DmNextInput.attack(id, shift)`: attack target; the first step is taken in the click, then `tick` each physics frame: out of the primary's range (`DmAbilities.shortfall`, the host's own check) = walk (one `request_move_to`, re-planned only when the enemy moved >= 1 m), in range = stop + cast the primary whenever `cooldown_left` is 0. The target is sticky (hold = repeat, cadence = the rite's cooldown) until it dies, WASD or a ground click |
| Shift + click | cast in place, never walks; holding Shift during a chase stops it; Shift on the ground just stands |
| queued cast | a deliberate key / RMB cast refused `busy`, or `cooldown` with <= 220 ms left, waits 220 ms and is retried every 50 ms; other refusals drop it |
| held number keys | repeat once held 150 ms and the rite is ready (only slots 1-5) |
| gesture | host `_apply_cast` -> `_gesture_cast` after a successful resolve: its own RPC (not an event), `avatar.cast(kind, seconds, yaw, gestureSeconds, ability)` once per accepted cast on every peer |
| hitstop | `DmHitStop` (min gap, leaky budget) fed by `enemy_fx` / `bosses.fx` (`host.hitstop_cb`: heavy hits, elite deaths, boss impacts); drives `Vfx.hitstop_scale`, `DmCreature.hitstop_scale` and the crowd's `hitstop_scale` (picture only); off under `reduce_motion` |
| shake | each owner's caster `shake_requested` -> `camera.shake` (honours `reduce_motion`) |
| runes | `rite_build()["runes"] = rune_sockets(peer)` = `DmRunes.sockets_of(bag)` for the local hero (necromancer), the server's record of a party member (`remote_builds`); `sync_runes()` on every bag change -> `DmRiteCaster.set_runes` |

Cost: `tick` returns on its first line when there is no target / queue / held key.

## Easy auto-combat, standing aim (`dm_next_auto.gd`, `DmNextAutoCombat`, owned by `DmNextInput.auto`)

The shared decision code in `client/game/` (`DmAutoCombat.select_action / select_movement`, `DmAutoDodge`, `DmBossTelegraphs`), fed by an adapter over the combat core: the enemies by the bulk arrays
(`enemy_ids / enemy_positions / enemy_states`, spawn order) and the facts the host's signals keep (radius, elite flag, health, wind-up, area), the corpses by `corpse_ids / corpse_positions` (within 40 m, at most 256), the
legion's size from the core, the caster (`cooldown_left`, essence), the hostile dust clouds and toxic pools from the `zone` events and the boss's telegraphs (`DmBossFx.played`). Output = the keyboard's intents:
`cast_at(slot, aim, enemy_id)` and `request_move_dir`. The decision code is built for speed (native sorts, each field read once); the adapter and its cost are client/next/perf/BENCHMARK-REPORT.md ("Easy auto combat").

| rule | here |
|---|---|
| gate | `settings_store.can_use_auto_combat()` (character `auto_combat_allowed`) AND `settings["auto_combat"]` (Easy only; the store forces it off otherwise). G / the button flip the setting (HUD) |
| hold position | `hold_position` (default off): casts but never walks; the in-game benchmark sets it so the hero holds the room centre |
| yields | walk in progress (click / WASD / held key), a click target, a queued cast, an open panel, gathering, dead hero; any family but the necromancers and the Reaper |
| cadence | movement every 100 ms, one action every 180 ms, direction intent re-sent every 150 ms, one ZERO when it stops; one compare per physics frame otherwise. It runs on the physics clock (`clock_ms`), so a game run faster than real time keeps its cadence |
| action | nearest-first targets, rite rotation (essence reserve, Exhume / Grave Offering / Rally / Carrion Seed / Mantle / Litany / Detonate / Cleave / Miasma / Prison / Hands / Storm / Siphon / Frost / Spear), corpse rites |
| the Reaper | `DmAutoCombat._reaper_action` (ctx `family` = "reaper", `player.souls`): Scythe Sweep as the free filler; souls go to Soul Burst (five in the blast, or a boss / elite with 14+ souls), Reap (a knot of three in the cone, a boss / elite, or 22+ souls), Harvest Spin (three on her) and Scythe Throw (a knot or an elite at range); while under 60 % health she keeps the 4 souls an escape needs; under 35 % health with a foe within 4.5 m she Wraith Walks straight away from it, and with 24+ souls she Wraith Walks to a foe 6-14 m off. She walks in to the sweep's 3.4 m reach like any melee primary |
| movement | leave telegraphs and hostile pools first, close to the primary's range, back off a pack, evade a wind-up, then hold. Closing, it looks along the straight line 5 times a second (`DmAutoNav.clear_line`, the core's navmesh grid) and when a grave or wall is in the way walks the navmesh's path round it (`DmAutoNav.find_path`, asked once in 0.8 s, ctx `routeNav`); a walk that moves the hero less than 0.3 m in a second takes the path for 2 s anyway (`stuckUntil`). The dodge never asks the navmesh (its many candidate spots would each cost a query) |
| extras | Healing flask under 42 % hp (belt, host), 2 %/s regen for 5 s after a hit |

Standing mouse-aim: `DmCombatInput.stand_face` from the 10 Hz hover pick -> `session.request_face(yaw)` (host `DmSessionBody.set_facing`: ignored while walking); a cast turns a standing hero to its aim
(`DmRiteCaster._face_aim`, so the gesture and the picture agree). Not while chasing, queued, casting, gathering, a panel is open or auto-combat has a target.

## Combat clarity (cues, slot needs, thrall health, number cap)
- **Cast cue**: every one of the 25 necromancer rites gives >= 3 visual calls and a sound within 0.25 s. Marrow Spear plays the existing `needleCast` whoosh at 0.9 on the press, because its own sound is the landing (`client/next/rites/rite_marrow_spear.gd`).
- **Slot needs**: a rite that cannot fire dims lightly and says "no corpse" / "no legion". `DmNextHudVm.NEEDS` maps the corpse rites and `rally_dead`, `command_rend` (legion). Rendering: `client/ui/hud/dm_hud_slot.gd`.
- **Thrall health**: the HUD's thrall pips of a thrall under 35 % health turn red (`DmNextHudVm.LOW_HP_ENTER`, `client/ui/hud/dm_hud_parts.gd`).
- **Damage-number cap**: `DmFloatBudget` (`client/next/hud/dm_float_budget.gd`, used by `DmNextUiHost.float_text`): hits + crits 14 (a crit gets +4), dot 5, thrall 6, hard total 22; hurt / gold / heal / info are never limited. The caps are judgement numbers: loosen if a crit-heavy build feels muted.

## Tests
`client/tests/auto_combat.gd` (Easy auto combat: seeded Full Party fights for the necromancer's rites and the Reaper's, the movement, the walk round what is in the way), `client/tests/auto_combat_play/run.gd` (the adapter on the game: the gate, targets, corpse rites, dodges, yields, the Reaper, and section J: three pockets of graves in the Graves, walked round, and the stuck watch), `client/tests/rites.gd` (the kit's hotbar, the click-to-attack chase, every rite's cast),
`client/tests/hud.gd` (slot needs, floating number caps), `client/tests/combat_odds/run.gd` (every rite's sounds and its visible and audible cue at the press), `client/tests/combat_clarity/run.gd` (the number cap, slot needs, thrall pips).

## Known gaps
- Auto-combat's dodge has no navigation of its own (the decision code's `nav` stays empty, since each candidate spot would cost a query), so a step out of a pool or telegraph can be into a pocket of graves; the walk toward an enemy has one (`DmAutoNav`).
- The old game's larger pulsing red ground ring under a thrall below 35 % health is not drawn on the crowd's thralls; only the HUD's pips turn red.
- Corpse marks inside the hero's reach are not brighter than others (needs a per-frame distance test).
- The Damage / Wave Speed upgrade panel overlapped the essence orb at 1280 x 800 on the old game (shared HUD layout, `client/ui/hud/`; not re-checked on the client).
- No boss-fight review of telegraph vs hero effect hues on real hardware.
