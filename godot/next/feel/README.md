# godot/next/feel: the necromancer's combat feel

Local-owner input logic (`dm_combat_input.gd`, `DmCombatInput`, owned by `DmNextInput.combat`) plus, elsewhere: gestures (`next/rites/dm_rite_gestures.gd`),
hitstop (`DmNextGame.hitstopper`), runes (`DmNextGame.rune_sockets / sync_runes`). All input is an ordinary intent (`request_move_to`, the hotbar seam), so it works online unchanged.

| feel | how |
|---|---|
| click an enemy | `DmNextInput.attack(id, shift)`: attack target; the first step is taken in the click, then `tick` each physics frame: out of the primary's range (`DmAbilities.shortfall`, the host's own check) = walk (one `request_move_to`, re-planned only when the enemy moved >= 1 m), in range = stop + cast the primary whenever `cooldown_left` is 0. The target is sticky (hold = repeat, cadence = the rite's cooldown) until it dies, WASD or a ground click |
| Shift + click | cast in place, never walks; holding Shift during a chase stops it; Shift on the ground just stands |
| queued cast | a deliberate key / RMB cast refused `busy`, or `cooldown` with <= 220 ms left, waits 220 ms and is retried every 50 ms; other refusals drop it |
| held number keys | repeat once held 150 ms and the rite is ready (only slots 1-5) |
| gesture | host `_apply_cast` -> `_gesture_cast` after a successful resolve: its own RPC (not an event), `avatar.cast(kind, seconds, yaw, gestureSeconds, ability)` once per accepted cast on every peer |
| hitstop | `DmHitStop` (min gap, leaky budget) fed by `enemy_fx` / `bosses.fx` (`host.hitstop_cb`: heavy hits, elite deaths, boss impacts); drives `Vfx.hitstop_scale` and `DmCreature.hitstop_scale` (picture only); off under `reduce_motion` |
| shake | each owner's caster `shake_requested` -> `camera.shake` (honours `reduce_motion`) |
| runes | `rite_build()["runes"] = rune_sockets(peer)` = `DmRunes.sockets_of(bag)` for the local host (necromancer); `sync_runes()` on every bag change -> `DmRiteCaster.set_runes` |

Cost: `tick` returns on its first line when there is no target / queue / held key (0.4-0.9 us); with a target ~30-40 us, no allocations. Tests: `tests/next_feel/run.gd` (44 checks).

## Easy auto-combat, standing aim (`dm_next_auto.gd`, `DmNextAutoCombat`, owned by `DmNextInput.auto`)

The shared decision code in `game/` (`DmAutoCombat.select_action / select_movement`, `DmAutoDodge`, `DmBossTelegraphs`), fed by an adapter over the nodes world:
`DmEnemy` (hp, radius, elite, windup = ATTACK state's WINDUP phase, area = meta `dm_area`), `DmBoss`, `DmCorpseField.corpses` (echo corpses left out), `DmThrallHost.places_used()`,
the caster (`cooldown_left`, essence), hostile pools (`dm_hostile_zone` group) and boss telegraphs (`DmBossFx.played`). Output = the keyboard's intents: `cast_at(slot, aim, enemy_id)` and `request_move_dir`.

| rule | here |
|---|---|
| gate | `settings_store.can_use_auto_combat()` (character `auto_combat_allowed`) AND `settings["auto_combat"]` (Easy only; the store forces it off otherwise). G / the button flip the setting (HUD) |
| yields | walk in progress (click / WASD / held key), a click target, a queued cast, an open panel, gathering, dead hero |
| cadence | movement every 100 ms, one action every 180 ms, direction intent re-sent every 150 ms, one ZERO when it stops; one compare per physics frame otherwise |
| action | nearest-first targets, rite rotation (essence reserve, Exhume / Grave Offering / Rally / Carrion Seed / Mantle / Litany / Detonate / Cleave / Miasma / Prison / Hands / Storm / Siphon / Frost / Spear), corpse rites |
| movement | leave telegraphs and hostile pools first, close to the primary's range, back off a pack, evade a wind-up, then hold |
| extras | Healing flask under 42 % hp (belt, host), 2 %/s regen for 5 s after a hit |

Standing mouse-aim: `DmCombatInput.stand_face` from the 10 Hz hover pick -> `session.request_face(yaw)` (host `DmSessionBody.set_facing`: ignored while walking); a cast turns a standing hero to its aim
(`DmRiteCaster._face_aim`, so the gesture and the picture agree). Not while chasing, queued, casting, gathering, a panel is open or auto-combat has a target.

Cost (headless, 14 enemies, 20 corpses): one decision ~1.5-2 ms (`select_action`) every 180 ms, idle tick 0.3 us; frame median 7.4 ms off vs 7.7 ms on. Tests: `tests/next_autocombat/run.gd`.

## Combat clarity (cues, slot needs, thrall health, number cap)
Locks: `tests/next_clarity/cues_run.gd`; audit tools `tests/next_clarity/audit.gd` (cue count per rite in the first 0.25 s and 4 s), `shoot.gd` (rendered Ossuary fight).
- **Cast cue**: every one of the 25 rites gives >= 3 visual calls and a sound within 0.25 s. Marrow Spear plays the existing `needleCast` whoosh at 0.9 on the press, because its own sound is the landing (`next/rites/rite_marrow_spear.gd`).
- **Slot needs**: a rite that cannot fire dims lightly and says "no corpse" / "no legion". `DmNextHudVm.NEEDS` maps the corpse rites and `rally_dead`, `command_rend` (legion); the test reads every `rite_*.gd` for `"no_corpse"` / `"no_thralls"` so a new rite cannot be forgotten. Rendering: `ui/hud/dm_hud_slot.gd`.
- **Thrall health**: a thrall under 35 % wears a larger pulsing red ground ring until back above 50 % (`DmThrall.LOW_HP_ENTER` / `LOW_HP_LEAVE`); HUD thrall pips under a third turn red (`ui/hud/dm_hud_parts.gd`).
- **Damage-number cap**: `DmFloatBudget` (`next/hud/dm_float_budget.gd`, used by `DmNextUiHost.float_text`): hits + crits 14 (a crit gets +4), dot 5, thrall 6, hard total 22; hurt / gold / heal / info are never limited. The caps are judgement numbers: loosen if a crit-heavy build feels muted.

## Tests
`tests/next_feel/run.gd` (behaviour, plus the wiring seams in section J), `tests/next_autocombat/run.gd`, `tests/next_clarity/`.

## Known gaps
- Auto-combat has no `DmNav` over the navmesh (the decision code's `clear_line` / path-around is skipped; the body's nav clamp slides it).
- No scythe `attack` gesture (no rite module); the Legend litany-shatter shake is a hook, not a rite.
- Remote peers' runes: only the local host's bag is known until the join handshake carries one.
- Corpse marks inside the hero's reach are not brighter than others (needs a per-frame distance test).
- The Damage / Wave Speed upgrade panel overlaps the essence orb at 1280 x 800 (shared HUD layout, `ui/hud/`).
- No boss-fight review of telegraph vs hero effect hues on real hardware.
