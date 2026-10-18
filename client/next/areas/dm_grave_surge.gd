class_name DmGraveSurge
extends RefCounted
## Grave Surges for the host's wave director, on the combat core (client/code.list "Ported"; the same rules and numbers as godot/next/areas/dm_grave_surge.gd: DmSimData.SURGE).
## Every SURGE interval (the first after firstDelayS) a crypt in the hero's combat area cracks open; three waves (waveAtS) of waveSize x
## waveSizeMult climb out of it; clear 80 % of what came within durationS and the crypt pays its offering (DmSessionRewards.on_surge_cleared).
## The director owns the clock: `update(dt, heroes)` while a hero is in the area, `reset()` when none is (a surge in an emptied area fails).
## A wave climbs out over a few ticks like an ordinary wave: its bodies go through the director's queue (SPAWNS_PER_TICK a tick) and the director hands each made body's core id back (`adopt`);
## what came is a set of those ids, and the director forwards every death (`on_enemy_died(id)`, from DmCoreHost.enemy_died): no node, scene or per-body work here.
## Events go out through `director.surge_event` ({t: surge | surgeCleared | surgeFailed, area, x, z, crypt, durationMs}); DmAreaFlow draws them on the host.
## A party guest gets no event: it sees the bodies climb out of the crypt (the core's snapshot) and, when the surge is quelled, its offering, but no banner, crypt, sound or tip (client/README.md "Grave Surges").

var director: DmWaveDirector
var active: bool = false
var area: String = ""
var pos := Vector3.ZERO
var spawned: int = 0
var killed: int = 0
var waves_spawned: int = 0
var age: float = 0.0
var serial: int = 0          ## bumped by every `start`: the bodies a surge queued carry its serial, so a surge that is over (or the next one) is never credited with them
var surge_in: float = -1.0   ## s of hero-in-combat-area time until the next surge (-1 = not set: SURGE.firstDelayS, read when the clock first runs)

static var _crypts: Array = []   ## DmDb.sim_world()["crypts"] (decoded once, when the first director is made: a fresh read is a file parse, which a first surge must not pay in a fight)

var _ids: Dictionary = {}        ## the core ids of what came (the queued bodies that were made) and has not died yet
var _ground_area := ""           ## the area `_ground_ok` was worked out for: the content is read when the director moves, not every tick
var _ground_ok := false          ## a combat ground (neither safe nor an instance)


func _init(director_: DmWaveDirector) -> void:
	director = director_
	if _crypts.is_empty():
		_crypts = DmDb.sim_world()["crypts"]


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
	if director.area_id != _ground_area:
		_ground_area = director.area_id
		var def: Dictionary = DmContent.area(_ground_area)
		_ground_ok = not bool(def.get("safe", true)) and not bool(def.get("instance", false))
	if not _ground_ok or heroes.is_empty() or director.kinds.is_empty():
		return false
	var g: Node = director.game
	if g == null or g.bosses == null:
		return true
	return g.bosses.bosses.is_empty() or g.bosses.living().is_empty()   # a boss fight is its own event (`living` makes an array: only asked while a boss stands)


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
	serial += 1
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


## One wave of the area's wave size x waveSizeMult (and the Wave Speed tier's size) at the crypt, at most up to the global cap (what is already queued counts: it will be in the core).
## Its bodies are queued through the director like an ordinary wave's, tagged with this surge's serial, and come back to `adopt` as they are made; `spawned` counts the wave when it is decided.
func _spawn_wave(heroes: Array) -> void:
	var d := director
	var tier := DmWaveUpgrades.wave_modifiers(DmEnemyStats.ramp_tier(d.wave_tier, d._since_arrival)) if d.wave_tier > 0.0 else {"sizeMult": 1.0}
	var def: Dictionary = DmContent.area(area)
	var room := int(DmSimData.GLOBAL_ENEMY_CAP) - d.enemy_total() - d.pending_count()
	var count := mini(room, DmMath.js_round(float(def["waveSize"]) * float(DmSimData.SURGE["waveSizeMult"]) * float(tier["sizeMult"])))
	var made := 0
	d.begin_surge_wave(serial)
	while made < count:
		var a := d.rng.randf() * TAU
		var r := 0.5 + d.rng.randf() * 2.4
		var at := pos + Vector3(cos(a) * r, 0.0, sin(a) * r)
		if d.game.world.nav_ready():
			at = d.game.world.nav_closest(at)
		var n := d.spawn_group(at, heroes, count - made)
		if n <= 0:
			break
		made += n
	d.end_surge_wave()
	spawned += made
	if made > 0:
		d.wave_spawned.emit(made)


## Host: the director made a body of this surge's queue and hands over its core id. It is kept only while that surge is the open one: a surge that ended with some of its bodies still
## queued, or the surge after it, is not credited with them.
func adopt(id: int, from: int) -> void:
	if active and from == serial:
		_ids[id] = true


## Host: an enemy of the core died (the director forwards every death, by its core id).
func on_enemy_died(id: int) -> void:
	if active and _ids.erase(id):
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
