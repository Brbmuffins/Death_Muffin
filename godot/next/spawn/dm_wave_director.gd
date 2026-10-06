class_name DmWaveDirector
extends Node
## Host-side enemy waves for one hunting ground, generic over enemy def ids, plus the replication of the enemies themselves.
##
## Spawning: only the host decides (`_physics_process`); every enemy is a DmEnemy scene created by a MultiplayerSpawner, so peers (and
## late joiners) get the same bodies even in a solo session (OfflineMultiplayerPeer). Their per-tick state travels in DmNextNet
## (get_net_state / apply_net_state). Kinds: the area's enemy table filtered to defs that have a scene at res://enemies/<id>.tscn.
## Pacing (simplified from the sim): a wave of `wave_size` every `wave_interval` s while a hero is in the area, up to `cap` alive.
## Scaling: DmEnemyStats (area level, hp/damage per level, party hp) fed to DmEnemy.hp_mult / damage_mult.

signal enemy_spawned(enemy: DmEnemy)    ## every peer, after the enemy is in the tree
signal enemy_died(enemy: DmEnemy)       ## host only
signal wave_spawned(count: int)         ## host only

const SCENE_DIR := "res://enemies/"
const CORPSE_S := 4.0
const EMPTY_CLEAR_S := 15.0             ## no hero in the area this long -> remaining enemies are removed
const SPAWN_MIN := 9.0
const SPAWN_MAX := 14.0                 ## inside DmEnemy.AGGRO_RANGE (15) so a wave notices the hero at once

var game: Node                          ## DmNextGame
var area_id: String = "graves"
var enabled: bool = true
var wave_interval: float = 6.5
var wave_size: int = 9
var cap: int = 28
var first_wave_delay: float = 1.0
var kinds: Array = []                   ## [{id, weight}] with a scene
var enemies: Dictionary = {}            ## id -> DmEnemy (every peer)
var waves_spawned: int = 0
var rng := RandomNumberGenerator.new()
var wave_tier: float = 0.0              ## the Wave Speed tier in force (DmWaveUpgrades.wave_modifiers: interval, size, cap, enemy hp / damage); see set_wave_tier

var _holder: Node3D
var _spawner: MultiplayerSpawner
var _next_id: int = 1
var _wave_t: float = 0.0
var _empty_t: float = 0.0
var _scene_cache: Dictionary = {}
var _base := [6.5, 9, 28]               ## the area's own interval / size / cap, before the tier
var _since_arrival: float = 0.0         ## s a hero has been in the area (Wave Speed ramps in over DmEnemyStats.RAMP_S, like the sim's ramp_tier)


func _ready() -> void:
	rng.randomize()
	_holder = Node3D.new()
	_holder.name = "Bodies"
	add_child(_holder)
	_spawner = MultiplayerSpawner.new()
	_spawner.name = "Spawner"
	add_child(_spawner)
	_spawner.spawn_path = NodePath("../Bodies")
	_spawner.spawn_function = Callable(self, "_spawn_enemy")
	configure_area(area_id)


## Wave Speed (the sim's formulas): the wave timer is divided by 1 + 0.12 d, a wave holds more (sizeMult), the area holds more (capMult).
## Enemy hp / damage scale at spawn from the ramped tier.
func set_wave_tier(tier: float) -> void:
	wave_tier = tier
	var m := DmWaveUpgrades.wave_modifiers(tier)
	wave_interval = float(_base[0]) * float(m["intervalMult"])
	wave_size = DmMath.js_round(float(_base[1]) * float(m["sizeMult"]))
	cap = DmMath.js_round(float(_base[2]) * float(m["capMult"]))


func configure_area(id: String) -> void:
	area_id = id
	var def: Dictionary = DmContent.area(id)
	wave_interval = float(def.get("waveIntervalMs", 6500)) / 1000.0
	wave_size = int(def.get("waveSize", 9))
	cap = int(def.get("cap", 28))
	_base = [wave_interval, wave_size, cap]
	if wave_tier != 0.0:
		set_wave_tier(wave_tier)
	kinds.clear()
	for e in def.get("enemies", []):
		if scene_for(String(e["id"])) != null:
			kinds.append({"id": String(e["id"]), "weight": float(e["weight"])})
	_wave_t = first_wave_delay


## Loading-time warm-up: scenes and creature models of every kind, so the first wave does not read them from disk mid-play.
func warm() -> void:
	for k in kinds:
		var def: Dictionary = DmSimData.ENEMIES[k["id"]]
		var cr := DmCreature.new(String(def.get("modelSlug", "grave_robber")), {})
		cr.root.free()


func scene_for(def_id: String) -> PackedScene:
	if not _scene_cache.has(def_id):
		var path := SCENE_DIR + def_id + ".tscn"
		_scene_cache[def_id] = load(path) if ResourceLoader.exists(path) else null
	return _scene_cache[def_id]


# ---- queries (every peer; the seam for rites / rewards) -----------------------------------------------------------------------

func enemy_by_id(id: int) -> DmEnemy:
	var e: Variant = enemies.get(id)
	return e if e != null and is_instance_valid(e) else null


## Living enemies whose centre is within `r` of `pos` (flat distance, minus the enemy's own radius: a big body counts from its edge).
func enemies_in_radius(pos: Vector3, r: float) -> Array[DmEnemy]:
	var out: Array[DmEnemy] = []
	for e in enemies.values():
		var en := e as DmEnemy
		if en == null or not is_instance_valid(en) or en.sm == null or en.sm.id() == DmEnemyState.Id.DEAD:
			continue
		var d := Vector2(en.global_position.x - pos.x, en.global_position.z - pos.z).length()
		if d - en.radius <= r:
			out.append(en)
	return out


func alive_count() -> int:
	var n := 0
	for e in enemies.values():
		var en := e as DmEnemy
		if en != null and is_instance_valid(en) and en.sm != null and en.sm.id() != DmEnemyState.Id.DEAD:
			n += 1
	return n


## Stable id of an enemy (same on every peer); 0 when it is not one of ours.
func enemy_id(e: Node) -> int:
	return int(e.get_meta(&"dm_id", 0)) if e != null else 0


static func id_of(e: DmEnemy) -> int:
	return int(e.get_meta(&"dm_id", 0))


# ---- host: waves ---------------------------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not enabled or game == null or not multiplayer.is_server() or not game.session.is_active():
		return
	var heroes := _heroes_in_area()
	if heroes.is_empty():
		_wave_t = first_wave_delay
		_since_arrival = 0.0
		_empty_t += delta
		if _empty_t > EMPTY_CLEAR_S and not enemies.is_empty():
			clear()
		return
	_empty_t = 0.0
	_since_arrival += delta
	_wave_t -= delta
	if _wave_t <= 0.0:
		_wave_t = wave_interval
		spawn_wave(heroes)


func _heroes_in_area() -> Array:
	var out: Array = []
	for b in game.session.get_bodies():
		var hb := b as DmHeroBody
		if hb != null and hb.alive and game.world.area_at(hb.position.x, hb.position.z) == area_id:
			out.append(hb)
	return out


func spawn_wave(heroes: Array, count: int = -1) -> int:
	if kinds.is_empty() or heroes.is_empty():
		return 0
	var n := mini(wave_size if count < 0 else count, cap - alive_count())
	var made := 0
	while made < n:
		var hero: DmHeroBody = heroes[rng.randi() % heroes.size()]
		var pos: Variant = _spawn_pos(hero.position)
		if pos == null:
			made += 1   # no walkable spot found: spend the slot so the loop ends
			continue
		var kind := _pick_kind()
		var pack: Variant = DmSimData.ENEMIES[kind].get("pack")   # bats / rats come in packs (sim: [min, max])
		var k := 1
		if pack is Array:
			k = rng.randi_range(int(pack[0]), int(pack[1]))
		var elite := pack == null and rng.randf() < float(DmContent.area(area_id).get("eliteChance", 0.0))
		for j in mini(k, cap - alive_count()):
			var at: Vector3 = pos if j == 0 else pos + Vector3(rng.randf_range(-1.5, 1.5), 0.0, rng.randf_range(-1.5, 1.5))
			if j > 0 and game.world.nav_ready():
				at = game.world.nav_closest(at)
			spawn(kind, at, heroes, elite)
		made += k
	if made > 0:
		waves_spawned += 1
		wave_spawned.emit(made)
	return made


## Host: create one enemy (replicated) and return it. `heroes` only feeds the level / party scaling. `mult` overrides the computed scaling
## ({level, hp, dmg}: the hp / damage multipliers as DmEnemy.hp_mult / damage_mult): a Risen raised by an acolyte or a deacon is as strong as its raiser.
func spawn(def_id: String, pos: Vector3, heroes: Array = [], elite: bool = false, mult: Dictionary = {}) -> DmEnemy:
	var levels: Array = []
	for h in heroes:
		levels.append(float((h as DmHeroBody).character.get("level", 1)))
	var level := DmEnemyStats.area_level(area_id, levels, 0.0)
	var tier := DmWaveUpgrades.wave_modifiers(DmEnemyStats.ramp_tier(wave_tier, _since_arrival)) if wave_tier > 0.0 else {"enemyHpMult": 1.0, "enemyDamageMult": 1.0}
	var e := _spawner.spawn({
		"id": _next_id, "def": def_id, "pos": pos, "level": float(mult.get("level", level)),
		"hp": float(mult["hp"]) if mult.has("hp") else DmEnemyStats.hp_scale(level) * DmEnemyStats.party_hp_scale(maxf(1.0, float(heroes.size()))) * float(tier["enemyHpMult"]),
		"dmg": float(mult["dmg"]) if mult.has("dmg") else DmEnemyStats.damage_scale(level) * float(tier["enemyDamageMult"]), "rising": true, "elite": elite})
	_next_id += 1
	return e as DmEnemy


## Host: a Risen climbs out at `at` for `by` (an acolyte's claimed thrall or a deacon's raised corpse), scaled like its raiser.
func _risen_for(at: Vector3, by: DmEnemy) -> DmEnemy:
	if by == null or not is_instance_valid(by):
		return null
	return spawn("risen", at, [], false, {"level": float(by.get_meta(&"dm_level", 1.0)), "hp": by.hp_mult, "dmg": by.damage_mult})


func _on_unbind_rise(at: Vector3, by: DmEnemy) -> void:
	var r := _risen_for(at, by)
	if r != null and by.has_method(&"adopt"):
		by.adopt(r)   # counts toward the acolyte's UNBIND.maxAlive


func _on_raised(at: Vector3, by: DmEnemy) -> void:
	_risen_for(at, by)


func _pick_kind() -> String:
	var total := 0.0
	for k in kinds:
		total += float(k["weight"])
	var roll := rng.randf() * total
	for k in kinds:
		roll -= float(k["weight"])
		if roll <= 0.0:
			return String(k["id"])
	return String(kinds[0]["id"])


## A walkable point 9-14 m from `around`, inside the area, at least 6 m away after snapping to the navmesh.
func _spawn_pos(around: Vector3) -> Variant:
	var rect: Dictionary = DmContent.area(area_id)["rect"]
	for _try in 10:
		var a := rng.randf() * TAU
		var r := rng.randf_range(SPAWN_MIN, SPAWN_MAX)
		var p := around + Vector3(sin(a), 0.0, cos(a)) * r
		p.x = clampf(p.x, float(rect["x0"]) + 1.5, float(rect["x1"]) - 1.5)
		p.z = clampf(p.z, float(rect["z0"]) + 1.5, float(rect["z1"]) - 1.5)
		if game.world.nav_ready():
			p = game.world.nav_closest(p)
		if Vector2(p.x - around.x, p.z - around.z).length() >= 6.0:
			return p
	return null


func clear() -> void:
	for e in enemies.values():
		if is_instance_valid(e):
			(e as Node).queue_free()   # the spawner replicates the despawn
	enemies.clear()


# ---- every peer: the spawn function --------------------------------------------------------------------------------------------

func _spawn_enemy(data: Variant) -> Node:
	var scene := scene_for(String(data["def"]))
	var e: DmEnemy = scene.instantiate()
	e.name = "E%d" % int(data["id"])
	e.def_id = String(data["def"])
	e.rising = bool(data["rising"])
	e.hp_mult = float(data["hp"])
	e.damage_mult = float(data["dmg"])
	e.elite = bool(data["elite"])
	e.position = data["pos"]
	(e.get_node("Nav") as NavigationAgent3D).path_height_offset = game.world.nav_y if game != null and game.world != null else 0.0
	e.set_meta(&"dm_id", int(data["id"]))
	e.set_meta(&"dm_level", float(data["level"]))
	e.set_meta(&"dm_elite", bool(data["elite"]))
	e.set_meta(&"dm_area", area_id)
	e.set_multiplayer_authority(1)
	var id := int(data["id"])
	enemies[id] = e
	e.tree_exiting.connect(func() -> void: enemies.erase(id))
	e.ready.connect(func() -> void: enemy_spawned.emit(e))
	if multiplayer.is_server():
		e.died.connect(_on_died)
		if e.has_signal(&"unbind_rise"):   # Lich Acolyte
			e.connect(&"unbind_rise", _on_unbind_rise)
		if e.has_signal(&"raised"):        # Crypt Deacon
			e.connect(&"raised", _on_raised.bind(e))
	return e


func _on_died(e: DmEnemy) -> void:
	enemy_died.emit(e)
	# The timer outlives the enemy (area change, teardown, clear()). A lambda capturing a freed Object logs "Lambda capture at index 0 was freed"
	# when called, even if its body guards with is_instance_valid (found by the next suite's intermittent engine-error check), so capture a WeakRef.
	var ref: WeakRef = weakref(e)
	get_tree().create_timer(CORPSE_S).timeout.connect(func() -> void:
		var dead: Node = ref.get_ref() as Node
		if dead != null:
			dead.queue_free())
