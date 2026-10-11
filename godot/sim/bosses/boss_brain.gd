class_name DmBossBrain
extends RefCounted
## Shared boss machinery, port of `BossBrain` in archive/legacy-web:src/gameplay/sim/BossBrain.ts: awaken, damage + Fracture + Withered, a host-owned
## stagger, phase thresholds at 60% / 30%, telegraphed attacks resolved on time, the wipe reset, defeat and the arena leash.
## Subclasses add their attacks in `_think` and how they land in `_resolve`. The brain only talks to a DmBossWorld.

const Content := preload("res://rules/core/content.gd")
const Geom := preload("res://sim/bosses/boss_geom.gd")
const Pending := preload("res://sim/bosses/boss_pending.gd")
const StableSort := preload("res://rules/inventory/stable_sort.gd")
const M := preload("res://rules/core/math.gd")

const BOSS_RADIUS := 1.6
## A boss ring strikes this far past its nominal radius (a body width); telegraphs draw it so the red is where the blow lands.
const BOSS_RING_PAD := 0.4

var world: RefCounted
var id: String = ""
var def: Dictionary = {}
## BossState (archive/legacy-web:src/gameplay/sim/types.ts) as a Dictionary: same keys, same meaning. `state["state"]` is the string state.
var state: Dictionary = {}
var pending: Array = []
var last_hit_by: String = ""
var stagger_t: float = 0.0
var _adds: Dictionary = {}
var _fracture: Dictionary
const STUCK_S := 0.6      ## seconds of no headway toward a reachable player before the boss asks for a route round (nav worlds)
const STUCK_FRAC := 0.3   ## "no headway" = it closed less than this share of the step it wanted
const DETOUR_S := 8.0     ## longest it follows a route round an obstacle before trying the straight line again
var _stuck_t := 0.0
const STICKY_GAIN := 0.7  ## another player must be closer than this share of the current target's range to take the boss over
const AVOID_S := 4.0      ## seconds a player the boss could not reach is skipped
var _target_id: Variant = null
var _avoid_id: Variant = null
var _avoid_t := 0.0
var state_dt := 0.0
var _detours_tried := 0
var _route := PackedVector2Array()
var _route_i := 0
var _detour_t := 0.0
var _empower: Dictionary
var _difficulties: Dictionary


func _init(world_: RefCounted, id_: String) -> void:
	world = world_
	id = id_
	def = Content.get_export("bosses", "BOSSES")[id_]
	_fracture = Content.get_export("abilities", "FRACTURE")
	_empower = Content.get_export("gameplay_goldSinkRules", "EMPOWER")
	_difficulties = Content.get_export("difficulty", "DIFFICULTIES")
	var areas: Dictionary = Content.get_export("areas", "AREAS")
	state = {
		"id": id_, "active": false, "x": float(arena()["x"]), "z": float(arena()["z"]), "facing": 0.0, "hp": 1.0, "maxHp": 1.0,
		"phase": 1, "state": "idle", "stateT": 0.0, "flash": 0.0, "fracture": 0, "fractureT": 0.0,
		"withered": 0, "witheredT": 0.0, "witheredDps": 0.0, "level": areas[def["area"]]["level"],
	}


func arena() -> Dictionary:
	return def["arena"]


func _ax() -> float:
	return float(def["arena"]["x"])


func _az() -> float:
	return float(def["arena"]["z"])


func _ar() -> float:
	return float(def["arena"]["r"])


# --- small helpers mirroring the TS ones ------------------------------------------------------------------------------

func _hp_scale(level: float) -> float:
	return 1.0 + 0.22 * (level - 1.0)


func _dmg_scale(level: float) -> float:
	return 1.0 + 0.15 * (level - 1.0)


func _diff() -> Dictionary:
	return _difficulties[world.difficulty()]


## `{kind, x, z, phase, boss, ...extra}`; null-valued extras are legal (dropped by comparison like undefined in TS).
func emit_boss(kind: String, x: float, z: float, extra: Dictionary = {}) -> void:
	var ev := {"t": "boss", "kind": kind, "x": x, "z": z, "phase": state["phase"], "boss": id}
	ev.merge(extra, true)
	world.emit(ev)


# --- lifecycle --------------------------------------------------------------------------------------------------------

## `empowered`: a Covenant Seal summon (goldSinkRules): the level knob goes up and so does the health.
func awaken(by: String, empowered: bool = false) -> void:
	if state["active"]:
		return
	var s := state
	var party := maxi(1, world.player_count())
	s["active"] = true
	s["empowered"] = empowered
	s["level"] = world.area_level(def["area"])
	if empowered:
		s["level"] = M.js_round(float(s["level"]) + float(_empower["levelsFlat"]) + float(s["level"]) * float(_empower["levelsShare"]))
	s["maxHp"] = float(def["baseHp"]) * _hp_scale(float(s["level"])) * (float(_empower["hpMult"]) if empowered else 1.0) * (1.0 + world.party_hp_per_extra() * float(party - 1)) * float(_diff()["enemyHpMult"])
	s["hp"] = s["maxHp"]
	s["phase"] = 1
	s["state"] = "idle"
	s["stateT"] = 0.0
	s["x"] = _ax()
	s["z"] = _az()
	s["facing"] = 0.0
	s["flash"] = 0.0
	s["fracture"] = 0
	s["fractureT"] = 0.0
	s["withered"] = 0
	s["witheredT"] = 0.0
	s["witheredDps"] = 0.0
	pending = []
	stagger_t = 0.0
	_adds.clear()
	last_hit_by = by
	_on_awaken()
	var extra := {"empowered": true} if empowered else {}
	var ev := {"t": "boss", "kind": "awaken", "x": s["x"], "z": s["z"], "phase": 1, "boss": id}
	ev.merge(extra, true)
	world.emit(ev)


func _on_awaken() -> void:
	pass


func _on_phase(_p: int) -> void:
	pass


func _think(_dt: float, _players: Array) -> void:
	pass


func _on_defeat() -> void:
	pass


## Host migration: rebuild what only the old host's brain knew (niches, pits). Cooldowns restart.
func resume() -> void:
	pass


## Adds belong to this attempt; they leave with the boss without granting a kill or a corpse.
func _spawn_add(def_id: String, x: float, z: float, elite: bool = false) -> int:
	var eid: int = world.spawn_enemy(def_id, def["area"], x, z, elite, true)
	_adds[eid] = true
	return eid


func _clear_adds() -> void:
	for eid in _adds:
		world.remove_enemy(eid)
	_adds.clear()


## Extra per-tick work before attacks (regen, hazards); runs after the stagger.
func _tick(_dt: float, _players: Array) -> void:
	pass


func damage(amount: float, by: String, fracture: int) -> void:
	var s := state
	if not s["active"] or float(s["hp"]) <= 0.0:
		return
	s["hp"] = float(s["hp"]) - amount * (1.0 + float(_fracture["perStack"]) * float(s["fracture"]))
	s["flash"] = 1.0
	last_hit_by = by
	if fracture:
		s["fracture"] = mini(int(_fracture["maxStacks"]), int(s["fracture"]) + fracture)
		s["fractureT"] = float(_fracture["durationMs"]) / 1000.0


## Pause movement, attacks and active telegraphs for a short host-owned stagger.
func stagger(seconds: float) -> void:
	if not state["active"] or float(state["hp"]) <= 0.0:
		return
	stagger_t = maxf(stagger_t, seconds)
	state["flash"] = 1.0


func _dmg(base: float) -> float:
	return base * _dmg_scale(float(state["level"])) * float(_diff()["enemyDamageMult"])


func _set_phase(p: int) -> void:
	state["phase"] = p
	emit_boss("phase", state["x"], state["z"])
	_on_phase(p)


## The living players inside this boss's area, in world order.
func _area_players() -> Array:
	var out: Array = []
	for p in world.players():
		if p["alive"] and p["area"] == def["area"]:
			out.append(p)
	return out


func update(dt: float) -> void:
	var s := state
	if not s["active"]:
		return
	s["flash"] = maxf(0.0, float(s["flash"]) - dt * 4.0)
	if float(s["fractureT"]) > 0.0:
		s["fractureT"] = float(s["fractureT"]) - dt
		if float(s["fractureT"]) <= 0.0:
			s["fracture"] = 0
	if float(s["witheredT"]) > 0.0 and int(s["withered"]) > 0:
		s["witheredT"] = float(s["witheredT"]) - dt
		# The Mire Mother is untouchable while sunk (damage() refuses her): rot ticks run out but do not bite.
		if s["state"] != "sunk":
			s["hp"] = float(s["hp"]) - float(s["withered"]) * float(s["witheredDps"]) * dt
		if float(s["witheredT"]) <= 0.0:
			s["withered"] = 0

	if float(s["hp"]) <= 0.0:
		s["active"] = false
		s["state"] = "dead"
		pending = []
		_on_defeat()
		_clear_adds()
		var extra := {"empowered": true} if s.get("empowered", false) else {}
		emit_boss("defeated", s["x"], s["z"], {"killer": last_hit_by}.merged(extra))
		return
	var ratio: float = float(s["hp"]) / float(s["maxHp"])
	if int(s["phase"]) == 1 and ratio <= 0.6:
		_set_phase(2)
	elif int(s["phase"]) == 2 and ratio <= 0.3:
		_set_phase(3)

	var players := _area_players()
	if players.is_empty():
		# Everyone left or fell: the boss resets and waits to be summoned again.
		s["active"] = false
		s["state"] = "idle"
		pending = []
		_on_defeat()
		_clear_adds()
		emit_boss("defeated", s["x"], s["z"], {"killer": ""})
		return

	# A stagger pauses the boss clock, including attacks already telegraphed.
	# The room clock keeps advancing, so move their due times forward too.
	if stagger_t > 0.0:
		var paused := minf(dt, stagger_t)
		stagger_t -= paused
		for attack in pending:
			attack.at += paused
		dt -= paused
		if dt <= 0.0:
			return
	s["stateT"] = float(s["stateT"]) + dt
	state_dt = dt
	_tick(dt, players)

	# Resolve telegraphed attacks.
	var now: float = world.now()
	for p in pending.duplicate():
		if now < p.at:
			continue
		for i in pending.size():
			if is_same(pending[i], p):
				pending.remove_at(i)
				break
		_resolve(p, players)
	_think(dt, players)


## Default resolution: circles (Prelate toll/slam/rain, and any boss's ring attack).
func _resolve(p, players: Array) -> void:
	var circles: Array = p.targets if p.targets != null else [[p.x, p.z]]
	var hurt := {}
	for c in circles:
		var cx: float = c[0]
		var cz: float = c[1]
		for pl in players:
			if hurt.has(pl["id"]) or Geom.hyp(pl["x"] - cx, pl["z"] - cz) > p.r + BOSS_RING_PAD:
				continue
			hurt[pl["id"]] = true
			world.emit({"t": "hurt", "player": pl["id"], "dmg": _dmg(_circle_damage(p.kind)), "from": "boss", "x": cx, "z": cz})
		_hurt_thralls(func(t): return Geom.hyp(t["x"] - cx, t["z"] - cz) <= p.r)
	emit_boss(p.kind, p.x, p.z, {"targets": p.targets, "r": p.r, "ms": 0})


func _circle_damage(_kind: String) -> float:
	return 20.0


func _hurt_thralls(inside: Callable, base: float = 20.0) -> void:
	for t in world.thralls():
		if not inside.call(t):
			continue
		world.damage_thrall(t["id"], _dmg(base))


## A cone / line / spoke hit on players: emits hurt for each caught body and returns their ids.
func _strike_players(players: Array, caught: Callable, base: float, x: float, z: float) -> Array:
	var ids: Array = []
	for pl in players:
		if not caught.call(pl):
			continue
		ids.append(pl["id"])
		world.emit({"t": "hurt", "player": pl["id"], "dmg": _dmg(base), "from": "boss", "x": x, "z": z})
	return ids


const _RAIN_KINDS := ["rotRain", "coals", "conflagration", "hands", "rite", "bury", "hymn", "grasp", "chorus", "communion"]
const _OWN_KINDS := ["toll", "slam", "rain", "summon"]


## `extra` may hold targets, dir, side (the Pending extras).
func _telegraph(kind: String, x: float, z: float, r: float, ms: float, extra: Dictionary = {}, delay_ms: float = 0.0) -> void:
	var p := Pending.new()
	p.kind = kind
	p.at = world.now() + (ms + delay_ms) / 1000.0
	p.x = x
	p.z = z
	p.r = r
	p.targets = extra.get("targets", null)
	p.dir = extra.get("dir", null)
	p.side = extra.get("side", false)
	pending.append(p)
	if not p.side:
		if kind in _OWN_KINDS:
			state["state"] = kind
		elif kind in _RAIN_KINDS:
			state["state"] = "rain"
		else:
			state["state"] = "slam"
		state["stateT"] = 0.0
	emit_boss(kind, x, z, {"targets": p.targets, "r": r, "ms": ms + delay_ms, "dir": p.dir})


func _busy() -> bool:
	for p in pending:
		if not p.side:
			return true
	return false


## Returns {"nearest": player, "nd": float}. On a nav world (the live game) the pick is sticky: the current target is kept until another player is
## clearly closer (STICKY_GAIN), so two heroes at similar range do not make the boss swing between them every tick; a player the boss
## could not get to (see _track_progress) is skipped for AVOID_S while anyone else is in the arena.
func _nearest(players: Array) -> Dictionary:
	var nav: bool = world.nav_active()
	var nearest: Dictionary = players[0]
	var nd := INF
	var cur: Variant = null
	var cur_d := INF
	for p in players:
		var d := Geom.hyp(p["x"] - float(state["x"]), p["z"] - float(state["z"]))
		if nav and p["id"] == _target_id:
			cur = p
			cur_d = d
		if nav and _avoid_t > 0.0 and p["id"] == _avoid_id and players.size() > 1:
			continue
		if d < nd:
			nd = d
			nearest = p
	if nav:
		if _avoid_t > 0.0:
			_avoid_t -= state_dt
		if cur != null and cur["id"] != nearest["id"] and not (_avoid_t > 0.0 and cur["id"] == _avoid_id and players.size() > 1) and nd >= cur_d * STICKY_GAIN:
			nearest = cur
			nd = cur_d
		if _target_id != nearest["id"]:
			_target_id = nearest["id"]
			_stuck_t = 0.0
			_detour_t = 0.0
	return {"nearest": nearest, "nd": nd}


## Lumber toward the nearest player, leashed inside the arena (radius - margin). `busy` < 0: use the live value.
## On a world with `nav_active()` the step is also kept on walkable ground, and a boss that makes no headway toward a player it could reach
## (a wall or pillar between them) walks the nav route's next waypoint for DETOUR_S before it tries the straight line again.
func _chase(nearest: Dictionary, nd: float, speed: float, dt: float, margin: float = 2.0, stop_at: float = 3.0, busy_override: int = -1) -> void:
	var s := state
	var busy := _busy() if busy_override < 0 else busy_override == 1
	if nd > stop_at:
		var nav: bool = world.nav_active()
		var px: float = s["x"]
		var pz: float = s["z"]
		var gx: float = nearest["x"]
		var gz: float = nearest["z"]
		var gd := nd
		if nav and _detour_t > 0.0:   # walking the route round an obstacle, waypoint by waypoint
			_detour_t -= dt
			while _route_i < _route.size() and Geom.hyp(_route[_route_i].x - px, _route[_route_i].y - pz) < 0.8:
				_route_i += 1
			if _route_i >= _route.size():
				_detour_t = 0.0
			else:
				gx = _route[_route_i].x
				gz = _route[_route_i].y
				gd = Geom.hyp(gx - px, gz - pz)
		var dx: float = gx - px
		var dz: float = gz - pz
		s["x"] = float(s["x"]) + (dx / gd) * speed * dt
		s["z"] = float(s["z"]) + (dz / gd) * speed * dt
		var ox: float = float(s["x"]) - _ax()
		var oz: float = float(s["z"]) - _az()
		var o_r := Geom.hyp(ox, oz)
		if o_r > _ar() - margin:
			s["x"] = _ax() + (ox / o_r) * (_ar() - margin)
			s["z"] = _az() + (oz / o_r) * (_ar() - margin)
		if nav:
			var w: Vector2 = world.walk(s["x"], s["z"])
			s["x"] = w.x
			s["z"] = w.y
			_track_progress(nearest, px, pz, speed * dt, dt, margin)
		s["state"] = s["state"] if busy else "move"
	else:
		_stuck_t = 0.0
	s["facing"] = atan2(nearest["x"] - float(s["x"]), nearest["z"] - float(s["z"]))


## Nav worlds: time spent not getting anywhere toward a target inside the leash; past STUCK_S ask the world for a route round the obstacle.
func _track_progress(nearest: Dictionary, px: float, pz: float, want: float, dt: float, margin: float) -> void:
	var s := state
	var moved := Geom.hyp(float(nearest["x"]) - px, float(nearest["z"]) - pz) - Geom.hyp(float(nearest["x"]) - float(s["x"]), float(nearest["z"]) - float(s["z"]))   # headway: the range closed
	var reachable := Geom.hyp(float(nearest["x"]) - _ax(), float(nearest["z"]) - _az()) < _ar() - margin
	if moved >= want * STUCK_FRAC or not reachable or want <= 0.0:
		_stuck_t = 0.0
		if moved >= want * STUCK_FRAC:
			_detours_tried = 0
		return
	_stuck_t += dt
	if _stuck_t < STUCK_S:
		return
	_stuck_t = 0.0
	var route: PackedVector2Array = world.detour(float(s["x"]), float(s["z"]), float(nearest["x"]), float(nearest["z"]))
	_detours_tried += 1
	if route.size() >= 2:
		_route = route
		_route_i = 1
		_detour_t = DETOUR_S
	if _detour_t <= 0.0 or _detours_tried >= 3:   # no way round, or the way round did not help: try someone else for a while
		_avoid_id = nearest["id"]
		_avoid_t = AVOID_S
		_detours_tried = 0


## A point on the arena rim (for adds and pits).
func _rim(angle: float, frac: float = 0.85) -> Array:
	return [_ax() + sin(angle) * _ar() * frac, _az() + cos(angle) * _ar() * frac]


## Sort players by distance to the boss (stable, like JS Array.sort).
func _by_distance(players: Array) -> Array:
	var sx := float(state["x"])
	var sz := float(state["z"])
	return StableSort.sorted(players, func(a, b): return (Geom.hyp(a["x"] - sx, a["z"] - sz) - Geom.hyp(b["x"] - sx, b["z"] - sz)) < 0.0)
