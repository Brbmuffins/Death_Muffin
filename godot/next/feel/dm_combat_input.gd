class_name DmCombatInput
extends RefCounted
## The necromancer's combat input feel on the rebuild (attack-target chase, hold repeat, queued casts,
## held number keys, Shift = cast in place). Local owner only; everything it does is an ordinary intent (`request_move_to` /
## `request_move_dir`, the hotbar signal -> request_cast), so the host stays authoritative and it works the same solo or online.
##
## Cheap by construction: `tick(now_ms)` returns at the first line when there is no target, no queued cast and no held key (the normal
## case), and a chase re-plans only when the enemy moved >= REPLAN_M or the body stopped, never every frame. No allocations in the tick.
##
##   click an enemy       -> `set_target(id, shift)`: chase into the primary's range, stop, cast the primary whenever it is ready (hold = repeat)
##   Shift + click enemy  -> the same, standing still (no chase)
##   key / RMB cast       -> `note_cast`; a refusal "busy" (or "cooldown" with <= QUEUE_MS left) queues it for QUEUE_MS and it fires when ready
##   number key held      -> repeats once HOLD_MS old and the rite is ready
##   standing, mouse seen -> `stand_face`: the hero turns toward the cursor; Easy auto-combat is DmNextAutoCombat.

const QUEUE_MS := 220.0       ## a cast refused for a lock / <= 220 ms of cooldown waits this long
const RETRY_MS := 50.0        ## minimum gap between two automatic cast requests (host refusals are cheap but an RPC for a client)
const HOLD_MS := 150.0        ## a number key repeats only once held this long (the press itself already cast)
const STAND_PAD := 0.25       ## the cursor must be this far from the hero to turn it
const FACE_STEP := 0.05       ## rad: a new facing is sent only when it moved this much
const REPLAN_M := 1.0         ## chase: re-plan the walk when the enemy moved this far from the last goal

var game: Node                                  ## DmNextGame
var input: DmNextInput
var target_id: int = 0                          ## the attack target (0 = none); sticky until it dies, the hero walks by hand or clicks ground
var stand: bool = false                         ## target set with Shift: cast in place, no chase
var shift_probe := Callable()                   ## () -> bool, tests swap it; default Input.is_key_pressed(KEY_SHIFT)
var queued: Dictionary = {}                     ## {slot, rite, aim, enemy_id, until, next, sent}
var stats := {"chase_moves": 0, "stops": 0, "primary_casts": 0, "queued": 0, "queue_fired": 0, "repeats": 0, "ticks": 0}

var _last := {"slot": 0, "rite": "", "aim": Vector3.ZERO, "enemy_id": 0, "manual": false}
var _caster: DmRiteCaster
var _chasing := false
var _goal := Vector3.INF
var _face_sent: float = 1000.0
var _next_primary: float = 0.0
var _held := {}                                 ## slot -> ms the key went down
var _held_next := {}                            ## slot -> earliest next repeat
var _pad := {"x": 0.0, "z": 0.0, "loadout": null}


func setup(game_: Node, input_: DmNextInput) -> void:
	game = game_
	input = input_


## The idle state the tick returns on immediately.
func idle() -> bool:
	return target_id == 0 and queued.is_empty() and _held.is_empty()


func set_target(enemy_id: int, shift: bool) -> void:
	target_id = enemy_id
	stand = shift
	queued = {}
	_goal = Vector3.INF
	_next_primary = 0.0
	_chasing = false
	if game != null and game.session.is_active():
		game.session.request_move_dir(Vector3.ZERO)   # the hero stops where it is (the chase, if any, starts from the next tick)


## Drop the target and the queue (ground click, WASD, death).
func clear() -> void:
	target_id = 0
	queued = {}
	_chasing = false


## A cast just left the hotbar seam (called by DmNextInput before it emits; a refusal can arrive synchronously on the host).
func note_cast(slot: int, rite: String, aim: Vector3, enemy_id: int, manual: bool) -> void:
	_last["slot"] = slot
	_last["rite"] = rite
	_last["aim"] = aim
	_last["enemy_id"] = enemy_id
	_last["manual"] = manual


func _on_rejected(rite: String, reason: String) -> void:
	if rite != String(_last["rite"]):
		return
	if not queued.is_empty() and String(queued["rite"]) == rite:
		if reason != "busy" and reason != "cooldown":
			queued = {}                       # essence / dead / range: waiting will not help
		return
	if not bool(_last["manual"]) or int(_last["slot"]) <= 0:
		return
	if reason == "busy" or (reason == "cooldown" and _caster != null and _caster.cooldown_left(rite) <= QUEUE_MS):
		var now := float(Time.get_ticks_msec())
		queued = {"slot": int(_last["slot"]), "rite": rite, "aim": _last["aim"], "enemy_id": int(_last["enemy_id"]), "until": now + QUEUE_MS, "next": now, "sent": false}
		stats["queued"] += 1


func _bind() -> DmRiteCaster:
	var b: DmHeroBody = game.local_body()
	var c := b.get_node_or_null("Rites") as DmRiteCaster if b != null else null
	if c != _caster:
		_caster = c
		if c != null and not c.cast_rejected.is_connected(_on_rejected):
			c.cast_rejected.connect(_on_rejected)
	return c


func _shift() -> bool:
	return bool(shift_probe.call()) if shift_probe.is_valid() else Input.is_key_pressed(KEY_SHIFT)


## A number key went down (DmNextInput, on the event); the repeat is verified against the action every tick, so a lost key-up cannot stick.
func key_down(slot: int, now: float) -> void:
	if slot >= 1 and slot <= 5:
		_held[slot] = now


## One physics frame. `now` is in milliseconds (Time.get_ticks_msec() in the game; tests pass their own clock).
func tick(now: float) -> void:
	if game == null:
		return
	if idle():
		return
	stats["ticks"] += 1
	var b: DmHeroBody = game.local_body()
	if b == null or not b.alive:
		clear()
		return
	var c := _bind()
	if c == null:
		return
	if not queued.is_empty():
		if _tick_queue(c, now):
			return
	for slot in _held.keys():                 # held number keys repeat only when the rite is ready (old: the first held key wins)
		if not Input.is_action_pressed(&"dm_hotbar_%d" % slot):
			_held.erase(slot)
			_held_next.erase(slot)
			continue
		var rite := String(game.rite_for_slot(slot))
		if rite != "" and now - float(_held[slot]) >= HOLD_MS and now >= float(_held_next.get(slot, 0.0)) and c.cooldown_left(rite) <= 0.0:
			_held_next[slot] = now + RETRY_MS
			stats["repeats"] += 1
			input.cast_slot(slot, false)
			return
	if target_id != 0:
		_tick_target(c, b, now)


func _tick_queue(c: DmRiteCaster, now: float) -> bool:
	var q := queued
	if now > float(q["until"]):
		queued = {}
		return false
	var rite := String(q["rite"])
	if c.cooldown_left(rite) > 0.0:
		if bool(q["sent"]):
			queued = {}                       # accepted: its cooldown runs
			stats["queue_fired"] += 1
			return true
		return false
	if now >= float(q["next"]):
		q["next"] = now + RETRY_MS
		q["sent"] = true
		input.cast_at(int(q["slot"]), q["aim"], int(q["enemy_id"]), false)
	return true


func _tick_target(c: DmRiteCaster, b: DmHeroBody, now: float) -> void:
	var e: DmEnemy = game.enemy_by_id(target_id)
	if e == null or not is_instance_valid(e) or not DmRiteCaster.alive_enemy(e) or not e.is_hittable():
		target_id = 0
		_halt()
		return
	var primary := String(game.rite_for_slot(0))
	if primary == "":
		return
	var ep := e.global_position
	_pad["x"] = b.position.x
	_pad["z"] = b.position.z
	_pad["loadout"] = c.p.get("loadout", DmWeaponLine.no_loadout()) if not c.p.is_empty() else DmWeaponLine.no_loadout()
	var is_boss := e is DmBoss
	var short := DmAbilities.shortfall(_pad, primary, {"x": ep.x, "z": ep.z, "boss": is_boss}, DmSimConsts.BOSS_RADIUS)
	if short > 0.0:
		if stand or _shift():
			_halt()                           # in place: out of range is a silent wait (the host would refuse the cast anyway)
		elif not _chasing or _goal.distance_to(ep) >= REPLAN_M:
			_goal = ep
			_chasing = true
			stats["chase_moves"] += 1
			game.session.request_move_to(Vector3(ep.x, 0.0, ep.z))
		return
	_halt()
	if now >= _next_primary and c.cooldown_left(primary) <= 0.0:
		_next_primary = now + RETRY_MS
		stats["primary_casts"] += 1
		input.cast_at(0, ep, target_id, false)


## Standing mouse-aim: turn the hero toward `point` (the cursor's ground point / hovered enemy) while it stands, casts nothing and auto-combat has
## no target. One intent (`request_face`) per ~3 degrees of change, nothing at all while walking / chasing / casting / gathering / a panel is open.
func stand_face(point: Vector3, auto_aim: bool) -> bool:
	if game == null or auto_aim or target_id != 0 or not queued.is_empty():
		return false
	var b: DmHeroBody = game.local_body()
	if b == null or not b.alive or not game.session.is_active() or input.held_direction() != Vector3.ZERO:
		return false
	if (b.has_target or b.move_dir.length_squared() > 0.0001) if not b.p.is_empty() else b.moving:   # the host knows; a puppet only sees the motion
		return false
	if not b.p.is_empty() and b.clock_ms() < float(b.p["castUntil"]):
		return false
	if (game.ui != null and game.ui.panel_open()) or (game.gather != null and game.gather.loop != null and game.gather.loop.active):
		return false
	var dx := point.x - b.position.x
	var dz := point.z - b.position.z
	if dx * dx + dz * dz <= STAND_PAD * STAND_PAD:
		return false
	var yaw := atan2(dx, dz)
	if absf(angle_difference(yaw, _face_sent)) < FACE_STEP and absf(angle_difference(yaw, b.yaw)) < FACE_STEP:
		return false
	_face_sent = yaw
	game.session.request_face(yaw)
	return true


## Stop a chase walk in place (one intent, only when one was running).
func _halt() -> void:
	if _chasing:
		_chasing = false
		stats["stops"] += 1
		if game != null and game.session.is_active():
			game.session.request_move_dir(Vector3.ZERO)
