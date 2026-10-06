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
signal procession(theme: Dictionary)    ## host: a themed wave (DmSimData.WAVE_THEMES) was spawned
signal area_followed(id: String)        ## host: the director moved to the combat area the heroes are in
signal surge_event(ev: Dictionary)      ## host: {t: surge | surgeCleared | surgeFailed, area, x, z, ...} (DmGraveSurge)

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
var difficulty: String = "medium"       ## DmNextMeta: Settings -> difficulty (DmContent.difficulty: enemy hp / damage, elite chance)
var vow_fx: Dictionary = {}             ## DmNextMeta: the sworn world vows' effects (levels, enemyHpMult, waveSizeMult, deaconMult, eliteBonus)
var omen: Dictionary = {}               ## DmNextMeta: the week's Omen (waveSizeMult, eliteBonus, affix)
var size_extra: float = 1.0             ## omen x vow wave-size multiplier (DmNextMeta); the sim folds it into the one rounded wave size

var _holder: Node3D
var _spawner: MultiplayerSpawner
var _next_id: int = 1
var _wave_t: float = 0.0
var _empty_t: float = 0.0
var _scene_cache: Dictionary = {}
var _base := [6.5, 9, 28]               ## the area's own interval / size / cap, before the tier
var follow_areas := true                ## host: when no hero is in `area_id`, move to the combat area one is in (DmNextGame: every area has a roster)
var surge: DmGraveSurge                 ## Grave Surges (next/areas/dm_grave_surge.gd), host
var _first_wave := true                 ## the first wave of a visit is 1.3 x the area's wave size (the sim's spawn_wave first)
var _wave_n: int = 0                    ## waves since arrival (processions start at PROCESSION.minWave)
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
	surge = DmGraveSurge.new(self)
	configure_area(area_id)


## Wave Speed (the sim's formulas): the wave timer is divided by 1 + 0.12 d, a wave holds more (sizeMult), the area holds more (capMult).
## Enemy hp / damage scale at spawn from the ramped tier.
func set_wave_tier(tier: float) -> void:
	wave_tier = tier
	var m := DmWaveUpgrades.wave_modifiers(tier)
	wave_interval = float(_base[0]) * float(m["intervalMult"])
	wave_size = DmMath.js_round(float(_base[1]) * float(m["sizeMult"]) * size_extra)
	cap = DmMath.js_round(float(_base[2]) * float(m["capMult"]))


func configure_area(id: String) -> void:
	area_id = id
	var def: Dictionary = DmContent.area(id)
	wave_interval = float(def.get("waveIntervalMs", 6500)) / 1000.0
	wave_size = int(def.get("waveSize", 9))
	cap = int(def.get("cap", 28))
	_base = [wave_interval, wave_size, cap]
	if wave_tier != 0.0 or size_extra != 1.0:
		set_wave_tier(wave_tier)
	kinds.clear()
	for e in def.get("enemies", []):
		if scene_for(String(e["id"])) != null:
			kinds.append({"id": String(e["id"]), "weight": float(e["weight"])})
	_wave_t = first_wave_delay
	_first_wave = true
	_wave_n = 0


## Loading-time warm-up: scenes and creature models of every kind, so the first wave does not read them from disk mid-play. `all_areas`: every
## area's roster and procession themes (DmNextGame: no first-entry hitch in any area).
func warm(all_areas: bool = false) -> void:
	var ids: Dictionary = {}
	for k in kinds:
		ids[String(k["id"])] = true
	if all_areas:
		for a in DmContent.area_order():
			for e in DmContent.area(String(a)).get("enemies", []):
				ids[String(e["id"])] = true
			for th in DmSimData.WAVE_THEMES.get(String(a), []):
				for e in th["roster"]:
					ids[String(e["id"])] = true
	for id in ids:
		if scene_for(id) == null:
			continue
		var def: Dictionary = DmSimData.ENEMIES[id]
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
	if heroes.is_empty() and follow_areas:
		var other := _combat_area_with_hero()
		if other != "" and other != area_id:
			clear_area(area_id)   # the old ground's; a Depths run's dead are the Depths'
			if surge != null:
				surge.reset()
			configure_area(other)
			area_followed.emit(other)
			heroes = _heroes_in_area()
	if heroes.is_empty():
		_wave_t = first_wave_delay
		_since_arrival = 0.0
		_first_wave = true
		_wave_n = 0
		_empty_t += delta
		if _empty_t > EMPTY_CLEAR_S and not enemies.is_empty():
			clear_area(area_id)   # only this ground's: another track's enemies (the Depths run) are not ours to sink
		if surge != null:
			surge.reset()
		return
	_empty_t = 0.0
	_since_arrival += delta
	_wave_t -= delta
	if _wave_t <= 0.0:
		_wave_t = wave_interval
		if _first_wave:
			_first_wave = false
			spawn_wave(heroes, DmMath.js_round(float(_base[1]) * 1.3))
		else:
			_wave_n += 1
			var theme: Variant = _roll_theme()
			if theme == null:
				spawn_wave(heroes)
			else:
				var th: Dictionary = theme
				var made := spawn_wave(heroes, maxi(1, DmMath.js_round(float(wave_size) * float(th["sizeMult"]))), th["roster"], String(th["lead"]) if th.get("lead") != null else "")
				if made > 0:
					procession.emit(th)
	if surge != null:
		surge.update(delta, heroes)


## A combat (non-instance, non-safe) area a living hero stands in, "" if none.
func _combat_area_with_hero() -> String:
	for b in game.session.get_bodies():
		var hb := b as DmHeroBody
		if hb == null or not hb.alive:
			continue
		var a: String = game.world.area_at(hb.position.x, hb.position.z)
		if a != "" and not _is_safe_or_instance(a):
			return a
	return ""


static func _is_safe_or_instance(id: String) -> bool:
	var def: Dictionary = DmContent.area(id)
	return bool(def.get("safe", true)) or bool(def.get("instance", false))


## The sim's procession: from wave PROCESSION.minWave on, a PROCESSION.chance of waves is themed (a roster, sometimes a lead, a size).
func _roll_theme() -> Variant:
	var themes: Array = DmSimData.WAVE_THEMES.get(area_id, [])
	if themes.is_empty() or _wave_n < int(DmSimData.PROCESSION["minWave"]) or rng.randf() >= float(DmSimData.PROCESSION["chance"]):
		return null
	return themes[rng.randi() % themes.size()]


func _heroes_in_area() -> Array:
	var out: Array = []
	for b in game.session.get_bodies():
		var hb := b as DmHeroBody
		if hb != null and hb.alive and game.world.area_at(hb.position.x, hb.position.z) == area_id:
			out.append(hb)
	return out


## A wave of `count` (default: the wave size) climbing in around the heroes. `roster` ([{id, weight}], default the area's) and `lead` (the first
## group's kind) are a procession's. Returns how many spawned.
func spawn_wave(heroes: Array, count: int = -1, roster: Array = [], lead: String = "") -> int:
	if kinds.is_empty() or heroes.is_empty():
		return 0
	var n := mini(wave_size if count < 0 else count, mini(cap - alive_count(), int(DmSimData.GLOBAL_ENEMY_CAP) - enemies.size()))
	var made := 0
	while made < n:
		var hero: DmHeroBody = heroes[rng.randi() % heroes.size()]
		var pos: Variant = _spawn_pos(hero.position)
		if pos == null:
			made += 1   # no walkable spot found: spend the slot so the loop ends
			continue
		made += spawn_group(pos, heroes, n - made, lead if made == 0 else "", roster)
	if made > 0:
		waves_spawned += 1
		wave_spawned.emit(made)
	return made


## The chance a single pick is an elite: the area's own + the Wave Speed ramp + difficulty + the Omen + Elite Surge (the sim's spawn_at_breach roll).
func elite_chance() -> float:
	var ramp := float(DmWaveUpgrades.wave_modifiers(DmEnemyStats.ramp_tier(wave_tier, _since_arrival))["eliteBonus"]) if wave_tier > 0.0 else 0.0
	return float(DmContent.area(area_id).get("eliteChance", 0.0)) + ramp + float(DmContent.difficulty(difficulty)["eliteBonus"]) \
		+ float(omen.get("eliteBonus", 0.0)) + float(vow_fx.get("eliteBonus", 0.0))


## One pick (a pack for bats / rats: sim [min, max]) around `pos`, at most `room` bodies. Elites are single picks. Returns how many spawned;
## `ids` collects the new enemies' ids.
func spawn_group(pos: Vector3, heroes: Array, room: int, lead: String = "", roster: Array = [], ids: Array = []) -> int:
	var kind := lead if lead != "" and scene_for(lead) != null else _pick_kind(roster)
	var pack: Variant = DmSimData.ENEMIES[kind].get("pack")
	var k := 1
	if pack is Array:
		k = rng.randi_range(int(pack[0]), int(pack[1]))
	var elite := pack == null and rng.randf() < elite_chance()
	var over := {}
	if not elite and wave_tier > 0.0 and DmWaveUpgrades.milestone_active("nightfall", DmEnemyStats.ramp_tier(wave_tier, _since_arrival)) and rng.randf() < DmSimData.NIGHTFALL_SHROUD_CHANCE:
		over["affix_list"] = PackedStringArray(["shrouded"])   # the sim rolls Nightfall's shroud once per pick, for the whole pack
	var made := mini(k, room)
	for j in made:
		var at: Vector3 = pos if j == 0 else pos + Vector3(rng.randf_range(-1.5, 1.5), 0.0, rng.randf_range(-1.5, 1.5))
		if j > 0 and game.world.nav_ready():
			at = game.world.nav_closest(at)
		var e := spawn(kind, at, heroes, elite, {}, over)   # (spawn returns the enemy)
		ids.append(id_of(e) if e != null else -1)
	return made


## Host: create one enemy (replicated) and return it. `heroes` only feeds the level / party scaling. `mult` overrides the computed scaling
## ({level, hp, dmg}: the hp / damage multipliers as DmEnemy.hp_mult / damage_mult): a Risen raised by an acolyte or a deacon is as strong as its raiser.
## `over` (optional): area (the ground the enemy counts as for level scaling and `dm_area`; a boss's adds belong to the boss's
## area), depth (the Depths run: its level, and full Wave Speed ramp like the sim's instance), aggro / leash (metres), affixes (meta),
## affix_list (PackedStringArray of elite affixes; an elite without one rolls its own: the Omen's forced affix, else one of four, + the Depths' extras).
func spawn(def_id: String, pos: Vector3, heroes: Array = [], elite: bool = false, mult: Dictionary = {}, over: Dictionary = {}) -> DmEnemy:
	var levels: Array = []
	for h in heroes:
		levels.append(float((h as DmHeroBody).character.get("level", 1)))
	var spawn_area := String(over.get("area", "")) if String(over.get("area", "")) != "" else area_id
	var level := DmEnemyStats.area_level(spawn_area, levels, float(vow_fx.get("levels", 0.0)), float(over.get("depth", 1.0)))   # Elder Dead: + levels
	var tier := DmWaveUpgrades.wave_modifiers(DmEnemyStats.ramp_tier(wave_tier, 1e9 if over.has("depth") else _since_arrival)) if wave_tier > 0.0 else {"enemyHpMult": 1.0, "enemyDamageMult": 1.0}
	var diff := DmContent.difficulty(difficulty)
	var affixes: PackedStringArray = over.get("affix_list", PackedStringArray())
	if affixes.is_empty() and elite:
		affixes = DmAffixSet.roll(true, String(omen.get("affix", "")) if omen.get("affix") != null else "", float(over["depth"]) if spawn_area == "depths" and over.has("depth") else -1.0, 0.0, rng.randf)
	var e := _spawner.spawn({
		"id": _next_id, "affix_list": affixes, "def": def_id, "pos": pos, "level": float(mult.get("level", level)), "area": spawn_area,
		"aggro": float(over.get("aggro", 0.0)), "leash": float(over.get("leash", 0.0)), "affixes": maxi(int(over.get("affixes", 0)), affixes.size()),
		"hp": float(mult["hp"]) if mult.has("hp") else DmEnemyStats.hp_scale(level) * DmEnemyStats.party_hp_scale(maxf(1.0, float(heroes.size()))) * float(tier["enemyHpMult"]) \
			* float(diff["enemyHpMult"]) * float(vow_fx.get("enemyHpMult", 1.0)),
		"dmg": float(mult["dmg"]) if mult.has("dmg") else DmEnemyStats.damage_scale(level) * float(tier["enemyDamageMult"]) * float(diff["enemyDamageMult"]), "rising": true, "elite": elite})
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


func _pick_kind(roster: Array = []) -> String:
	var from: Array = roster if not roster.is_empty() else kinds
	var dm := float(vow_fx.get("deaconMult", 1.0))   # Deacon Host vow: deacons weigh more
	var total := 0.0
	for k in from:
		total += float(k["weight"]) * (dm if k["id"] == "deacon" else 1.0)
	var roll := rng.randf() * total
	for k in from:
		roll -= float(k["weight"]) * (dm if k["id"] == "deacon" else 1.0)
		if roll <= 0.0 and scene_for(String(k["id"])) != null:
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


## Remove the enemies that belong to one ground (meta dm_area).
func clear_area(area: String) -> void:
	for id in enemies.keys():
		var e: Node = enemies[id]
		if not is_instance_valid(e):
			enemies.erase(id)
		elif String(e.get_meta(&"dm_area", area_id)) == area:
			e.queue_free()
			enemies.erase(id)


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
	e.set_meta(&"dm_area", String(data.get("area", area_id)))
	if float(data.get("aggro", 0.0)) > 0.0:
		e.aggro_range = float(data["aggro"])
		e.leash_range = float(data["leash"])
	if int(data.get("affixes", 0)) > 0:
		e.set_meta(&"dm_affixes", int(data["affixes"]))
	var affix_list: PackedStringArray = data.get("affix_list", PackedStringArray())
	if not affix_list.is_empty():
		DmAffixSet.attach(e, affix_list, self)   # elite affixes: a component only on the bodies that carry one
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
	if surge != null:
		surge.on_enemy_died(e)
	# The timer outlives the enemy (area change, teardown, clear()). A lambda capturing a freed Object logs "Lambda capture at index 0 was freed"
	# when called, even if its body guards with is_instance_valid (found by the next suite's intermittent engine-error check), so capture a WeakRef.
	var ref: WeakRef = weakref(e)
	get_tree().create_timer(CORPSE_S).timeout.connect(func() -> void:
		var dead: Node = ref.get_ref() as Node
		if dead != null:
			dead.queue_free())
