class_name DmPlayer
extends RefCounted
## Port of src/gameplay/Player.ts: the local player's body. The numbers (vitals, defence, souls, cooldowns) live in `p`, the
## DmPlayerRules state Dictionary (shared with the rite caster); this class adds the walking half: click paths over DmNav, WASD steps,
## teleport, facing. Movement is client-simulated; positions are plain floats on the XZ plane (never Vector2: float32).

const PLAN_MS := 250.0

var p: Dictionary
var nav: DmNav
var moving := false
## Queued waypoints ([x, z] pairs).
var _path: Array = []
var _plan_at := -1e12


func _init(state: Dictionary, nav_: DmNav) -> void:
	p = state
	nav = nav_
	p["area"] = "chapterhouse"
	p["moving"] = false
	p["loadout"] = DmWeaponLine.no_loadout()
	p["runes"] = {}


var x: float:
	get: return float(p["x"])
	set(v): p["x"] = v
var z: float:
	get: return float(p["z"])
	set(v): p["z"] = v
var facing: float:
	get: return float(p["facing"])
	set(v): p["facing"] = v
var alive: bool:
	get: return bool(p["alive"])
var hp: float:
	get: return float(p["hp"])
	set(v): p["hp"] = v
var area: String:
	get: return String(p.get("area", ""))
	set(v): p["area"] = v


func max_hp() -> float:
	return float(p["stats"]["maxHp"])


func essence() -> float:
	return float(p["resource"]["value"])


func teleport(nx: float, nz: float) -> void:
	var r := nav.resolve(nx, nz, 0.45)
	p["x"] = r[0]
	p["z"] = r[1]
	_path = []
	p["area"] = nav.area_at(r[0], r[1])


func destination() -> Variant:
	if _path.is_empty():
		return null
	var d: Array = _path[_path.size() - 1]
	return {"x": d[0], "z": d[1]}


func has_path() -> bool:
	return not _path.is_empty()


## Walk to a clicked point, around props and walls. Chasing a moving target calls this every frame: within PLAN_MS of the last
## plan and a short hop from the old goal only the last waypoint moves; the full plan is redone after PLAN_MS.
func move_to(tx: float, tz: float) -> void:
	var d: Variant = destination()
	if d != null and DmSimMath.hypot(d["x"] - tx, d["z"] - tz) < 0.35:
		return
	var now := float(Time.get_ticks_usec()) / 1000.0
	if d != null and now - _plan_at < PLAN_MS and DmSimMath.hypot(d["x"] - tx, d["z"] - tz) < 2.0:
		var last: Array = _path[_path.size() - 1]
		last[0] = tx
		last[1] = tz
		return
	_plan_at = now
	_path = nav.find_path(x, z, tx, tz)


func move_along(path: Array) -> void:
	_path = []
	for w in path:
		_path.append([float(w[0]), float(w[1])])


func stop() -> void:
	_path = []


func face(fx: float, fz: float) -> void:
	p["facing"] = DmFdlibm.atan2_(fx - x, fz - z)


func heal(amount: float) -> void:
	DmPlayerRules.heal(p, amount)


func revive() -> void:
	DmPlayerRules.revive(p)


func take_damage(raw: float, ward_pct: float, now: float, from: Variant, source: String, guard: float) -> float:
	var taken := DmPlayerRules.take_damage(p, raw, ward_pct, now, from, source, guard)
	if not alive:
		_path = []
	return taken


## Vitals + one step. `key_dir` = {x, z} (WASD / auto-move) or null. Returns true if moved.
func update(dt: float, now: float, key_dir: Variant) -> bool:
	moving = false
	p["moving"] = false
	DmPlayerRules.tick_vitals(p, dt, now)
	if not alive:
		return false
	if now < float(p["rootedUntil"]):
		return false
	var speed := DmPlayerRules.move_speed(p, now)
	var dx := 0.0
	var dz := 0.0
	if key_dir != null and (float(key_dir["x"]) != 0.0 or float(key_dir["z"]) != 0.0):
		_path = []
		var ln := DmSimMath.hypot(key_dir["x"], key_dir["z"])
		dx = (float(key_dir["x"]) / ln) * speed * dt
		dz = (float(key_dir["z"]) / ln) * speed * dt
	elif not _path.is_empty():
		while not _path.is_empty() and DmSimMath.hypot(_path[0][0] - x, _path[0][1] - z) < 0.2:
			_path.pop_front()
		if _path.is_empty():
			return false
		var wp: Array = _path[0]
		var ddx: float = wp[0] - x
		var ddz: float = wp[1] - z
		var d := DmSimMath.hypot(ddx, ddz)
		var step := minf(d, speed * dt)
		dx = (ddx / d) * step
		dz = (ddz / d) * step
	if dx == 0.0 and dz == 0.0:
		return false
	var r := nav.resolve(x + dx, z + dz, 0.45)
	var moved := DmSimMath.hypot(r[0] - x, r[1] - z)
	if moved < speed * dt * 0.1 and not _path.is_empty():
		_path.pop_front()
	if moved > 1e-4:
		p["facing"] = DmFdlibm.atan2_(r[0] - x, r[1] - z)
		moving = true
		p["moving"] = true
	p["x"] = r[0]
	p["z"] = r[1]
	var a := nav.area_at(r[0], r[1])
	if a != "":
		p["area"] = a
	return moving
