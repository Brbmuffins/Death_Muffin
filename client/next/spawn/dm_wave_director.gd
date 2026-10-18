class_name DmWaveDirector
extends Node
## Host-side enemy waves for one hunting ground, generic over enemy def ids, on the combat core: a body is made by `DmCoreHost.spawn_enemy` (the core owns
## it from then on: no scene, no node, no spawner) and every query is an id.
##
## Pacing (simplified from the sim): a wave of `wave_size` every `wave_interval` s while a hero is in the area, up to `cap` alive.
## Scaling: DmEnemyStats (area level, hp/damage per level, party hp) fed to the core as the body's hp and damage multipliers.
## Counts come from the core: `alive_count()` (not dead) and `enemy_total()` (dying bodies count for 4 s until the core removes them).

signal wave_spawned(count: int)         ## host only
signal procession(theme: Dictionary)    ## host: a themed wave (DmSimData.WAVE_THEMES) was spawned
signal area_followed(id: String)        ## host: the director moved to the combat area the heroes are in
signal surge_event(ev: Dictionary)      ## host: {t: surge | surgeCleared | surgeFailed, area, x, z, ...} (DmGraveSurge)

## The defs the core's enemy brain runs: the Hollow Graves' roster, the rat of the kennel
## procession and the risen, the Ossuary's golem and deacon (so the whole Ossuary roster), the Drowned Nave's censer, acolyte, gargoyle, templar and wraith
## (so the whole Nave roster), the Weeping Seraph, Flagellant and Plague Doctor (so the Bell Sanctum, the Bone Coliseum and the Plague Cloister run their whole rosters)
## and the Cinder Pyre's and the Mourning Fen's cinder_husk, cinderhound, pyre_priest, slag_brute, bog_hag, drowned_sexton, fen_wisp and mire_leech (so the whole Pyre and Fen rosters).
## The other areas' kinds come with the core items that run them; a roster entry outside this list is skipped like a kind without a scene was.
const CORE_KINDS: Array[String] = ["robber", "hound", "penitent", "sac", "moth", "bat", "ghoul", "rat", "risen", "golem", "deacon", "censer", "acolyte", "gargoyle", "templar", "wraith",
	"seraph", "flagellant", "plague_doctor", "cinder_husk", "pyre_priest", "cinderhound", "slag_brute", "bog_hag", "drowned_sexton", "fen_wisp", "mire_leech"]
const BOSS_KINDS: Array[String] = ["niche"]   ## kinds only a boss makes (the Bone Abbess's Skull Niche: never in a wave's roster, always through `spawn`)
const EMPTY_CLEAR_S := 15.0             ## no hero in the area this long -> the area's remaining enemies are sent away
const SPAWN_MIN := DmSimConsts.AGGRO_RANGE + 3.0   ## owner 2026-10-07: waves climb in outside aggro so the player sees them coming (+3: a group fans out 2.1 m)
const SPAWN_MAX := 30.0                 ## farthest spawn distance (m)
const SPAWNS_PER_TICK := 3              ## wave bodies made per physics tick: a 12-body wave takes 4 ticks

var game: Node                          ## DmNextGame
var core_host: DmCoreHost:
	set(host):
		core_host = host
		if host != null and not host.enemy_died.is_connected(_on_enemy_died):
			host.enemy_died.connect(_on_enemy_died)   # every death, by core id, for the open Grave Surge
var area_id: String = "graves"
var enabled: bool = true
var wave_interval: float = 6.5
var wave_size: int = 9
var cap: int = 28
var first_wave_delay: float = 1.0
var kinds: Array = []                   ## [{id, weight}] the core can run
var waves_spawned: int = 0
var rng := RandomNumberGenerator.new()
var wave_tier: float = 0.0              ## the Wave Speed tier in force (DmWaveUpgrades.wave_modifiers: interval, size, cap, enemy hp / damage); see set_wave_tier
var difficulty: String = "medium"       ## DmNextMeta: Settings -> difficulty (DmContent.difficulty: enemy hp / damage, elite chance)
var vow_fx: Dictionary = {}             ## DmNextMeta: the sworn world vows' effects (levels, enemyHpMult, waveSizeMult, deaconMult, eliteBonus)
var omen: Dictionary = {}               ## DmNextMeta: the week's Omen (waveSizeMult, eliteBonus, affix)
var size_extra: float = 1.0             ## omen x vow wave-size multiplier (DmNextMeta); the sim folds it into the one rounded wave size
var spawn_min: float = SPAWN_MIN        ## wave spawn distance from the hero (the in-game benchmark brings it in for its small room)
var spawn_max: float = SPAWN_MAX
var fixed_stats: Dictionary = {}        ## benchmark only: {hp, dmg} every enemy gets whatever its kind, level or raiser (no elites); {} = play's scaling
var enemy_limit: int = -1               ## bodies alive or dying at once (-1 = DmSimData.GLOBAL_ENEMY_CAP); the benchmark's Heavy fight raises it

var _wave_t: float = 0.0
var _empty_t: float = 0.0
var _base := [6.5, 9, 28]               ## the area's own interval / size / cap, before the tier
var follow_areas := true                ## host: when no hero is in `area_id`, move to the combat area one is in (DmNextGame: every area has a roster)
var surge: DmGraveSurge                 ## Grave Surges (next/areas/dm_grave_surge.gd), host; its clock runs from `_physics_process` while a hero is in a combat area
var off: Dictionary = {}                ## defs the director leaves out as if the core did not run them (def id -> true; client/tests/core_kinds.gd leaves out the Bellringers' censer with it)
var _first_wave := true                 ## the first wave of a visit is 1.3 x the area's wave size (the sim's spawn_wave first)
var _wave_n: int = 0                    ## waves since arrival (processions start at PROCESSION.minWave)
var _vanguard := false                  ## this wave carries the Elite Vanguard (every other wave): its first plain pick is an elite
var _pending: Array[Dictionary] = []    ## host: wave spawns decided (kind, position, scaling) but not yet made, drained SPAWNS_PER_TICK per tick (a Grave Surge's carry its serial in "surge")
var _staging := false                   ## spawn_wave (or a Grave Surge's wave) is queueing its bodies
var _surge_serial := 0                  ## a Grave Surge is queueing its wave: the serial each queued body carries, so `_make_next` can hand the surge the body's core id (0 = an ordinary wave's)
var _since_arrival: float = 0.0         ## s a hero has been in the area (Wave Speed ramps in over DmEnemyStats.RAMP_S, like the sim's ramp_tier)


func _ready() -> void:
	rng.randomize()
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
		if makes(String(e["id"])):
			kinds.append({"id": String(e["id"]), "weight": float(e["weight"])})
	_wave_t = first_wave_delay
	_first_wave = true
	_wave_n = 0


## True when the combat core runs this def's brain (see CORE_KINDS).
static func runs_on_core(def_id: String) -> bool:
	return CORE_KINDS.has(def_id) or BOSS_KINDS.has(def_id)


## True when this director makes the def: the core runs it and `off` does not leave it out.
func makes(def_id: String) -> bool:
	return CORE_KINDS.has(def_id) and not off.has(def_id)


# ---- queries (the seam for rites / rewards) -------------------------------------------------------------------------------------

## Bodies that are not dead (RISING ones count, as the sim's alive_enemy).
func alive_count() -> int:
	return core_host.alive_count()


## Bodies in the core, the dead ones until they are removed (the global cap counts them for 4 s).
func enemy_total() -> int:
	return core_host.enemy_total()


## Wave bodies decided but not made yet.
func pending_count() -> int:
	return _pending.size()


# ---- host: waves -----------------------------------------------------------------------------------------------------------------

## Make every queued wave body now (tests and scripted setups that read the core right after `spawn_wave`).
func flush_spawns() -> void:
	while not _pending.is_empty():
		_make_next()


## The next queued body is made in the core. A Grave Surge's carries the surge's serial: the surge is handed its core id and keeps it only while that surge is the open one.
func _make_next() -> void:
	var data: Dictionary = _pending.pop_front()
	var id := _make(data)
	if surge != null and data.has("surge"):
		surge.adopt(id, int(data["surge"]))


## A Grave Surge's wave goes through the same queue as an ordinary wave's, SPAWNS_PER_TICK bodies a tick; every body queued between `begin_surge_wave` and `end_surge_wave`
## carries the surge's `serial` (DmGraveSurge._spawn_wave).
func begin_surge_wave(serial: int) -> void:
	_staging = true
	_surge_serial = serial


func end_surge_wave() -> void:
	_staging = false
	_surge_serial = 0


func _physics_process(delta: float) -> void:
	if not _pending.is_empty():
		for _i in mini(SPAWNS_PER_TICK, _pending.size()):
			_make_next()
	if not enabled or game == null or not multiplayer.is_server() or not game.session.is_active():
		return
	var heroes := _heroes_in_area()
	if heroes.is_empty() and follow_areas:
		var other := _combat_area_with_hero()
		if other != "" and other != area_id:
			clear_area(area_id)   # the old ground's queued spawns; a Depths run's dead are the Depths'
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
		if _empty_t > EMPTY_CLEAR_S and _empty_t - delta <= EMPTY_CLEAR_S:   # once, as the time runs out
			clear_area(area_id)
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
			_vanguard = _wave_n % 2 == 1 and milestone("vanguard")
			var theme: Variant = _roll_theme()
			if theme == null:
				spawn_wave(heroes)
			else:
				var th: Dictionary = theme
				var made := spawn_wave(heroes, maxi(1, DmMath.js_round(float(wave_size) * float(th["sizeMult"]))), th["roster"], String(th["lead"]) if th.get("lead") != null else "")
				if made > 0:
					procession.emit(th)
			_vanguard = false
	if surge != null:
		surge.update(delta, heroes)


## Every body of the core that died, by its id: a Grave Surge counts the ones it brought up (connected when `core_host` is set).
func _on_enemy_died(id: int, _def: String, _level: int, _elite: bool, _area: String, _source: int, _x: float, _z: float) -> void:
	if surge != null:
		surge.on_enemy_died(id)


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
	var limit := enemy_limit if enemy_limit > 0 else int(DmSimData.GLOBAL_ENEMY_CAP)
	var n := mini(wave_size if count < 0 else count, mini(cap - alive_count() - _pending.size(), limit - enemy_total() - _pending.size()))
	var made := 0
	_staging = true
	while made < n:
		var hero: DmHeroBody = heroes[rng.randi() % heroes.size()]
		var pos: Variant = _spawn_pos(hero.position)
		if pos == null:
			made += 1   # no walkable spot found: spend the slot so the loop ends
			continue
		made += spawn_group(pos, heroes, n - made, lead if made == 0 else "", roster)
	_staging = false
	if made > 0:
		waves_spawned += 1
		wave_spawned.emit(made)
	return made


## A Wave Speed milestone (Elite Vanguard tier 3, Restless Crypts 6, Nightfall 8) in force at the ramped tier, as the sim's director reads it.
func milestone(id: String) -> bool:
	return wave_tier > 0.0 and DmWaveUpgrades.milestone_active(id, DmEnemyStats.ramp_tier(wave_tier, _since_arrival))


## The chance a single pick is an elite: the area's own + the Wave Speed ramp + difficulty + the Omen + Elite Surge (the sim's spawn_at_breach roll).
func elite_chance() -> float:
	if not fixed_stats.is_empty():
		return 0.0
	var ramp := float(DmWaveUpgrades.wave_modifiers(DmEnemyStats.ramp_tier(wave_tier, _since_arrival))["eliteBonus"]) if wave_tier > 0.0 else 0.0
	return float(DmContent.area(area_id).get("eliteChance", 0.0)) + ramp + float(DmContent.difficulty(difficulty)["eliteBonus"]) \
		+ float(omen.get("eliteBonus", 0.0)) + float(vow_fx.get("eliteBonus", 0.0))


## One pick (a pack for bats / rats: sim [min, max]) around `pos`, at most `room` bodies. Elites are single picks. Returns how many spawned;
## `ids` collects the new enemies' core ids (-1 for a body that is queued, which a wave's are).
func spawn_group(pos: Vector3, heroes: Array, room: int, lead: String = "", roster: Array = [], ids: Array = []) -> int:
	var kind := lead if lead != "" and makes(lead) else _pick_kind(roster)
	var pack: Variant = DmSimData.ENEMIES[kind].get("pack")
	var k := 1
	if pack is Array:
		k = rng.randi_range(int(pack[0]), int(pack[1]))
	var vanguard := _vanguard and pack == null and lead == "" and kind != "risen"   # Elite Vanguard: the wave's first plain pick (the sim's force_elite)
	var elite := pack == null and (vanguard or rng.randf() < elite_chance())
	if elite:
		_vanguard = false
	var over := {}
	# Nightfall: common dead rise Shrouded — the real affix, rolled once per pick for the whole pack as the sim does
	if not elite and milestone("nightfall") and rng.randf() < DmSimData.NIGHTFALL_SHROUD_CHANCE:
		over["affix_list"] = PackedStringArray(["shrouded"])
	var made := mini(k, room)
	for j in made:
		var at: Vector3 = pos if j == 0 else pos + Vector3(rng.randf_range(-1.5, 1.5), 0.0, rng.randf_range(-1.5, 1.5))
		if j > 0 and game.world.nav_ready():
			at = game.world.nav_closest(at)
		var id := spawn(kind, at, heroes, elite, {}, over)
		ids.append(id if id > 0 else -1)
	return made


## The hero levels the world scales to. Solo: the heroes' own (the highest wins, DmEnemyStats.area_level). In a party the world follows the
## PARTY LEADER (the host) whoever is standing where, so a joiner who is stronger, weaker or not yet profiled never moves the enemies' level.
func scaling_levels(heroes: Array) -> Array:
	var levels: Array = []
	if heroes.is_empty():
		return levels
	var lead: DmHeroBody = game.local_body() if game.session.get_bodies().size() > 1 else null
	if lead != null and lead.is_inside_tree():
		levels.append(float(lead.character.get("level", 1)))
		return levels
	for h in heroes:
		levels.append(float((h as DmHeroBody).character.get("level", 1)))
	return levels


## Host: make one enemy in the core and return its id (0 while it is queued by `spawn_wave` or a Grave Surge's wave, whose bodies are made over the next ticks). `heroes` only
## feeds the level / party scaling. `mult` overrides the computed scaling ({level, hp, dmg}: the hp / damage multipliers; a Risen raised by a
## deacon or unbound by an acolyte is made by the core itself, with its raiser's level and multipliers). `over` (optional): area (the ground
## the enemy counts as for level scaling; a boss's adds belong to the boss's area), depth (the Depths run: its level, and full Wave Speed ramp like the
## sim's instance), aggro / leash (metres: this body's own notice and chase distances, as the Depths give theirs; the core's every-body defaults when absent),
## affix_list (PackedStringArray of elite affixes; an elite without one rolls its own: the Omen's forced affix, else one of four, + the
## Depths' extras). The affix roll is `DmAffixRoll.roll`, from this director's random stream.
func spawn(def_id: String, pos: Vector3, heroes: Array = [], elite: bool = false, mult: Dictionary = {}, over: Dictionary = {}) -> int:
	var levels := scaling_levels(heroes)
	var spawn_area := String(over.get("area", "")) if String(over.get("area", "")) != "" else area_id
	var level := DmEnemyStats.area_level(spawn_area, levels, float(vow_fx.get("levels", 0.0)), float(over.get("depth", 1.0)))   # Elder Dead: + levels
	var tier := DmWaveUpgrades.wave_modifiers(DmEnemyStats.ramp_tier(wave_tier, 1e9 if over.has("depth") else _since_arrival)) if wave_tier > 0.0 else {"enemyHpMult": 1.0, "enemyDamageMult": 1.0}
	var diff := DmContent.difficulty(difficulty)
	var affixes: PackedStringArray = over.get("affix_list", PackedStringArray())
	if affixes.is_empty() and elite:
		affixes = DmAffixRoll.roll(true, String(omen.get("affix", "")) if omen.get("affix") != null else "", float(over["depth"]) if spawn_area == "depths" and over.has("depth") else -1.0, 0.0, rng.randf)
	if not fixed_stats.is_empty():   # the benchmark: every kind takes the same hits to kill and hits as hard
		var d: Dictionary = DmSimData.ENEMIES[def_id]
		mult = {"level": level, "hp": float(fixed_stats["hp"]) / maxf(1.0, float(d["hp"])), "dmg": float(fixed_stats["dmg"]) / maxf(1.0, float(d["damage"]))}
		elite = false
		affixes = PackedStringArray()
	var data := {
		"def": def_id, "pos": pos, "level": int(mult.get("level", level)), "area": spawn_area, "affixes": affixes, "rising": true, "elite": elite,
		"aggro": float(over.get("aggro", 0.0)), "leash": float(over.get("leash", 0.0)),
		"hp": float(mult["hp"]) if mult.has("hp") else DmEnemyStats.hp_scale(level) * DmEnemyStats.party_hp_scale(maxf(1.0, float(heroes.size()))) * float(tier["enemyHpMult"]) \
			* float(diff["enemyHpMult"]) * float(vow_fx.get("enemyHpMult", 1.0)),
		"dmg": float(mult["dmg"]) if mult.has("dmg") else DmEnemyStats.damage_scale(level) * float(tier["enemyDamageMult"]) * float(diff["enemyDamageMult"])}
	if _staging:
		if _surge_serial != 0:
			data["surge"] = _surge_serial
		_pending.append(data)   # a wave's bodies are made over the next few ticks (spawn_wave, a Grave Surge's wave)
		return 0
	return _make(data)


func _make(data: Dictionary) -> int:
	return core_host.spawn_enemy(String(data["def"]), data["pos"], int(data["level"]), float(data["hp"]), float(data["dmg"]), bool(data["elite"]), String(data["area"]),
		bool(data["rising"]), data["affixes"], float(data["aggro"]), float(data["leash"]))


func _pick_kind(roster: Array = []) -> String:
	var from: Array = roster if not roster.is_empty() else kinds
	var dm := float(vow_fx.get("deaconMult", 1.0))   # Deacon Host vow: deacons weigh more
	var total := 0.0
	for k in from:
		total += float(k["weight"]) * (dm if k["id"] == "deacon" else 1.0)
	var roll := rng.randf() * total
	for k in from:
		roll -= float(k["weight"]) * (dm if k["id"] == "deacon" else 1.0)
		if roll <= 0.0 and makes(String(k["id"])):
			return String(k["id"])
	return String(kinds[0]["id"])


## A walkable point spawn_min-spawn_max (SPAWN_MIN-SPAWN_MAX in play) m from `around`, inside the area. Clamping to the area edge or snapping to the navmesh can pull a
## point back toward the hero: such tries are rejected, and if every try lands short the farthest one (at least 6 m) is used.
func _spawn_pos(around: Vector3) -> Variant:
	var rect: Dictionary = DmContent.area(area_id)["rect"]
	var best: Variant = null
	var best_d := 6.0
	for _try in 10:
		var a := rng.randf() * TAU
		var r := rng.randf_range(spawn_min, spawn_max)
		var p := around + Vector3(sin(a), 0.0, cos(a)) * r
		p.x = clampf(p.x, float(rect["x0"]) + 1.5, float(rect["x1"]) - 1.5)
		p.z = clampf(p.z, float(rect["z0"]) + 1.5, float(rect["z1"]) - 1.5)
		if game.world.nav_ready():
			p = game.world.nav_closest(p)
		var d := Vector2(p.x - around.x, p.z - around.z).length()
		if d >= spawn_min:
			return p
		if d >= best_d:
			best = p
			best_d = d
	return best


## Drop the queued spawns.
func clear() -> void:
	_pending.clear()


## Drop the queued spawns that belong to one ground and send its living bodies away (no death, corpse, credit or
## loot), so the global cap is free for the ground the heroes are on: when the director follows the heroes into another area, and when an area has
## been empty EMPTY_CLEAR_S. A body already dying finishes its fall; a boss is not in the core's table (the boss host's).
func clear_area(area: String) -> void:
	_pending = _pending.filter(func(d: Dictionary) -> bool: return String(d["area"]) != area)
	if core_host == null:
		return
	for id in core_host.core.enemy_ids():
		var info: Dictionary = core_host.core.enemy_info(id)
		if String(info.get("area", "")) == area and int(info.get("state", DmCoreEvents.State.DEAD)) != DmCoreEvents.State.DEAD:
			core_host.remove_enemy(id)
