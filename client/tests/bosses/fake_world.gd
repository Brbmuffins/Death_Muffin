class_name DmFakeBossWorld
extends "res://sim/bosses/boss_world.gd"
## Reference DmBossWorld used by the tests: the GDScript twin of StubWorld in (the retired web game\'s fixtures-bosses exporter). It records everything
## the brain asks of the world in `log`, in order, in the same shape as the TS fixture log.

const Rng := preload("res://rules/core/rng.gd")

var time: float = 0.0
var diff: String = "medium"
var echoes_n: int = 0
var level: int = 1
var rng: RefCounted
var player_list: Array = []
var enemy_map: Dictionary = {}   # id -> dict (insertion ordered)
var thrall_map: Dictionary = {}
var corpse_map: Dictionary = {}
var zone_map: Dictionary = {}
var cover_boxes: Array = []
var log: Array = []
var _next_id := 1000
var _next_zone := 1


func _init(seed_value: int, difficulty_: String, level_: int) -> void:
	rng = Rng.new(seed_value)
	diff = difficulty_
	level = level_


func now() -> float:
	return time


func difficulty() -> String:
	return diff


func echoes() -> int:
	return echoes_n


func rand() -> float:
	return rng.next()


func area_level(_area: String) -> int:
	return level


func emit(ev: Dictionary) -> void:
	log.append({"k": "emit", "ev": ev.duplicate(true)})


func players() -> Array:
	return player_list


func cover() -> Array:
	return cover_boxes


func spawn_enemy(def: String, area: String, x: float, z: float, elite: bool, rising: bool = true) -> int:
	var e := {"id": _next_id, "def": def, "area": area, "x": x, "z": z, "elite": elite, "hp": 100.0, "max_hp": 100.0, "state": "idle"}
	_next_id += 1
	enemy_map[e["id"]] = e
	log.append({"k": "spawn", "id": e["id"], "def": def, "area": area, "x": x, "z": z, "elite": elite, "rising": rising})
	return e["id"]


func enemy_get(id: int) -> Dictionary:
	return enemy_map.get(id, {})


func enemies() -> Array:
	return enemy_map.values()


func set_enemy_hp(id: int, hp: float, max_hp: float) -> void:
	if enemy_map.has(id):
		enemy_map[id]["hp"] = hp
		enemy_map[id]["max_hp"] = max_hp


func remove_enemy(id: int) -> void:
	enemy_map.erase(id)


func thralls() -> Array:
	return thrall_map.values()


func damage_thrall(id: int, amount: float) -> void:
	var t: Dictionary = thrall_map[id]
	t["hp"] = float(t["hp"]) - amount
	t["flash"] = 1.0
	if float(t["hp"]) <= 0.0:
		thrall_map.erase(id)
		log.append({"k": "killThrall", "id": id, "reason": "killed"})


func corpses() -> Array:
	return corpse_map.values()


func remove_corpse(id: int, reason: String) -> void:
	if corpse_map.erase(id):
		log.append({"k": "rmCorpse", "id": id, "reason": reason})


func hostile_toxic_zones() -> Array:
	var out: Array = []
	for z in zone_map.values():
		if z["kind"] == "toxic":
			out.append(z)
	return out


func add_hostile_pool(x: float, z: float, r: float, dps: float, seconds: float) -> void:
	log.append({"k": "hostilePool", "x": x, "z": z, "r": r, "dps": dps, "seconds": seconds})
	zone_map[_next_zone] = {"id": _next_zone, "kind": "toxic", "x": x, "z": z, "r": r, "until": time + seconds}
	_next_zone += 1


func ember_pool(x: float, z: float, r: float, seconds: float, dps: float) -> void:
	log.append({"k": "emberPool", "x": x, "z": z, "r": r, "seconds": seconds, "dps": dps})
	zone_map[_next_zone] = {"id": _next_zone, "kind": "ember", "x": x, "z": z, "r": r, "until": time + seconds}
	_next_zone += 1


func expire_zones() -> void:
	for id in zone_map.keys():
		if time >= float(zone_map[id]["until"]):
			zone_map.erase(id)
