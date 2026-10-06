class_name DmGraveSurge
extends RefCounted
## Grave Surges for the host's wave director (DmSimDirector.update_surge / start_surge / spawn_surge_wave, same numbers: DmSimData.SURGE).
## Every SURGE interval (the first after firstDelayS) a crypt in the hero's combat area cracks open; three waves (waveAtS) of waveSize x
## waveSizeMult climb out of it; clear 80 % of what came within durationS and the crypt pays its offering (DmSessionRewards.on_surge_cleared).
## The director owns the clock: `update(dt, heroes)` while a hero is in the area, `reset()` when none is (a surge in an emptied area fails).
## Events go out through `director.surge_event` ({t: surge | surgeCleared | surgeFailed, area, x, z, crypt, durationMs}); DmAreaFlow draws them.

var director: DmWaveDirector
var active: bool = false
var area: String = ""
var pos := Vector3.ZERO
var spawned: int = 0
var killed: int = 0
var waves_spawned: int = 0
var age: float = 0.0
var surge_in: float = -1.0   ## s of hero-in-combat-area time until the next surge (-1 = not set: SURGE.firstDelayS, read when the data is loaded)

static var _crypts: Array = []   ## DmDb.sim_world()["crypts"] (decoded once: a fresh read is a file parse)

var _ids: Dictionary = {}


func _init(director_: DmWaveDirector) -> void:
	director = director_


func update(dt: float, heroes: Array) -> void:
	if active:
		_tick(dt, heroes)
		return
	if not _eligible(heroes):
		return
	if surge_in < 0.0:
		surge_in = float(DmSimData.SURGE["firstDelayS"])
	surge_in -= dt
	if surge_in <= 0.0:
		start(heroes)


func _eligible(heroes: Array) -> bool:
	var def: Dictionary = DmContent.area(director.area_id)
	if bool(def.get("safe", true)) or bool(def.get("instance", false)) or heroes.is_empty() or director.kinds.is_empty():
		return false
	var g: Node = director.game
	return g == null or g.bosses == null or g.bosses.living().is_empty()   # a boss fight is its own event


## Open a surge now (also the test / QA entry point). Returns false when one is already open or the area has no ground for it.
func start(heroes: Array) -> bool:
	if active or heroes.is_empty():
		return false
	var crypt: Variant = _crypt_for(heroes)
	var at: Variant = crypt
	if at == null:
		at = director._spawn_pos((heroes[0] as Node3D).position)
	if at == null:
		return false
	active = true
	area = director.area_id
	pos = at
	spawned = 0
	killed = 0
	waves_spawned = 0
	age = 0.0
	_ids.clear()
	director.surge_event.emit({"t": "surge", "area": area, "x": pos.x, "z": pos.z, "durationMs": float(DmSimData.SURGE["durationS"]) * 1000.0, "crypt": crypt != null})
	return true


## A crypt of this area 9-30 m from every hero (the sim's fair breach rule), else null.
func _crypt_for(heroes: Array) -> Variant:
	var pool: Array = []
	if _crypts.is_empty():
		_crypts = DmDb.sim_world()["crypts"]
	for c in _crypts:
		if String(c["area"]) != director.area_id:
			continue
		var good := true
		for h in heroes:
			var d := DmSimMath.hypot((h as Node3D).position.x - float(c["x"]), (h as Node3D).position.z - float(c["z"]))
			if d < DmSimConsts.SPAWN_MIN_DIST or d > DmSimConsts.SPAWN_MAX_DIST:
				good = false
				break
		if good:
			pool.append(Vector3(float(c["x"]), 0.0, float(c["z"])))
	return pool[director.rng.randi() % pool.size()] if not pool.is_empty() else null


func _tick(dt: float, heroes: Array) -> void:
	age += dt
	var S: Dictionary = DmSimData.SURGE
	var at: Array = S["waveAtS"]
	while waves_spawned < at.size() and age >= float(at[waves_spawned]):
		waves_spawned += 1
		_spawn_wave(heroes)
	if waves_spawned >= at.size() and spawned > 0 and float(killed) >= float(spawned) * float(S["clearFrac"]):
		var ev := {"t": "surgeCleared", "area": area, "x": pos.x, "z": pos.z}
		_end()
		director.surge_event.emit(ev)
	elif age >= float(S["durationS"]):
		fail()


func _spawn_wave(heroes: Array) -> void:
	var d := director
	var tier := DmWaveUpgrades.wave_modifiers(DmEnemyStats.ramp_tier(d.wave_tier, d._since_arrival)) if d.wave_tier > 0.0 else {"sizeMult": 1.0}
	var def: Dictionary = DmContent.area(area)
	var room := int(DmSimData.GLOBAL_ENEMY_CAP) - d.enemies.size()
	var count := mini(room, DmMath.js_round(float(def["waveSize"]) * float(DmSimData.SURGE["waveSizeMult"]) * float(tier["sizeMult"])))
	var made := 0
	var ids: Array = []
	while made < count:
		var a := d.rng.randf() * TAU
		var r := 0.5 + d.rng.randf() * 2.4
		var at := pos + Vector3(cos(a) * r, 0.0, sin(a) * r)
		if d.game.world.nav_ready():
			at = d.game.world.nav_closest(at)
		var n := d.spawn_group(at, heroes, count - made, "", [], ids)
		if n <= 0:
			break
		made += n
	for id in ids:
		_ids[int(id)] = true
	spawned += made
	if made > 0:
		d.wave_spawned.emit(made)


## Host: an enemy died (the director forwards every death).
func on_enemy_died(e: DmEnemy) -> void:
	if active and _ids.erase(DmWaveDirector.id_of(e)):
		killed += 1


## The surge ran out (or its area emptied): the crypt seals, no offering.
func fail() -> void:
	if not active:
		return
	var ev := {"t": "surgeFailed", "area": area, "x": pos.x, "z": pos.z}
	_end()
	director.surge_event.emit(ev)


## No hero in the area: an open surge fails (the clock keeps its value; it ticks only while a hero is in a combat area).
func reset() -> void:
	fail()


func _end() -> void:
	active = false
	_ids.clear()
	var S: Dictionary = DmSimData.SURGE
	surge_in = (float(S["minIntervalS"]) + director.rng.randf() * (float(S["maxIntervalS"]) - float(S["minIntervalS"]))) \
		* (DmSimData.RESTLESS_SURGE_MULT if DmWaveUpgrades.milestone_active("restless", director.wave_tier) else 1.0)   # Restless Crypts: 40 % sooner
