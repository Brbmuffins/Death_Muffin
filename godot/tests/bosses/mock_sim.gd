class_name DmMockSim
extends RefCounted
## A stand-in for DmWorldSim with exactly the members BOSS_HOOK.md promises, built from the sim's entity classes. Used by
## adapter_run.gd to check DmBossFactory/DmBossAdapter/DmSimBossWorld against the same golden fixtures.

const Rng := preload("res://rules/core/rng.gd")
const SimEnemy := preload("res://sim/sim_enemy.gd")
const SimZone := preload("res://sim/sim_zone.gd")

var time: float = 0.0
var difficulty: String = "medium"
var vowFx: Dictionary = {"echoes": 0}
var players: Dictionary = {}
var enemies: Dictionary = {}
var thralls: Dictionary = {}
var corpses: Dictionary = {}
var zones: Dictionary = {}
var cover: Array = []
var log: Array = []
var level: int = 1
var _rng
var _next_id := 1000
var _next_zone := 1


func _init(seed_value: int, difficulty_: String, level_: int) -> void:
	_rng = Rng.new(seed_value)
	difficulty = difficulty_
	level = level_


func rand() -> float:
	return _rng.next()


func area_level(_area: String) -> float:
	return float(level)


func emit(ev: Dictionary) -> void:
	log.append({"k": "emit", "ev": ev.duplicate(true)})


func spawn_enemy(def: String, area: String, x: float, z: float, elite: bool, rising: bool = true, _affix: String = ""):
	var e := SimEnemy.new()
	e.id = _next_id
	_next_id += 1
	e.def = def
	e.area = area
	e.x = x
	e.z = z
	e.elite = elite
	e.hp = 100.0
	e.maxHp = 100.0
	e.state = "idle"
	enemies[e.id] = e
	log.append({"k": "spawn", "id": e.id, "def": def, "area": area, "x": x, "z": z, "elite": elite, "rising": rising})
	return e


func remove_corpse(c, reason: String, _by: String = "") -> void:
	if corpses.erase(c.id):
		log.append({"k": "rmCorpse", "id": c.id, "reason": reason})


func kill_thrall(t, reason: String) -> void:
	if thralls.erase(t.id):
		log.append({"k": "killThrall", "id": t.id, "reason": reason})


func add_hostile_pool(x: float, z: float, r: float, dps: float, seconds: float):
	log.append({"k": "hostilePool", "x": x, "z": z, "r": r, "dps": dps, "seconds": seconds})
	return _zone("toxic", x, z, r, seconds)


func ember_pool(x: float, z: float, r: float, seconds: float, dps: float):
	log.append({"k": "emberPool", "x": x, "z": z, "r": r, "seconds": seconds, "dps": dps})
	return _zone("ember", x, z, r, seconds)


func _zone(kind: String, x: float, z: float, r: float, seconds: float):
	var zn := SimZone.new()
	zn.id = _next_zone
	_next_zone += 1
	zn.kind = kind
	zn.x = x
	zn.z = z
	zn.r = r
	zn.until = time + seconds
	zn.hostile = true
	zones[zn.id] = zn
	return zn


func expire_zones() -> void:
	for id in zones.keys():
		if time >= zones[id].until:
			zones.erase(id)
