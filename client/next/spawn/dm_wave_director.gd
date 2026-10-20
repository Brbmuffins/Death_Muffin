class_name DmWaveDirector
extends Node
## Host-side enemy waves for the hunting grounds the party stands in, generic over enemy def ids, on the combat core: a body is made by `DmCoreHost.spawn_enemy` (the core owns
## it from then on: no scene, no node, no spawner) and every query is an id.
##
## Pacing (simplified from the sim): a wave of `wave_size` every `wave_interval` s while a hero is in the area, up to `cap` alive.
## Areas: the director serves one area, `area_id` (and its `cap`, `wave_size`, `wave_interval`, `kinds`: the Ground in hand), and moves to the combat area a hero is in when
## nobody is in its own. In a party, every other combat area a member stands in is served too, by a ground of its own with its own clock (`_extra`); the global cap is shared.
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


## One area's wave clock: its roster, cap, wave size and interval (from the area, then the Wave Speed tier) and where its timers stand. The director holds the ground it serves in `_g`
## (what `area_id`, `cap`, `wave_size`, `wave_interval` and `kinds` read) and one more for every other combat area a party member stands in (`_extra`).
class Ground:
	extends RefCounted
	var area_id := "graves"
	var wave_interval := 6.5
	var wave_size := 9
	var cap := 28
	var base: Array = [6.5, 9, 28]       ## the area's own interval / size / cap, before the tier
	var kinds: Array = []                ## [{id, weight}] the core can run
	var wave_t := 0.0                    ## s until the next wave
	var empty_t := 0.0                   ## s with no hero in the area
	var first_wave := true               ## the first wave of a visit is 1.3 x the area's wave size (the sim's spawn_wave first)
	var wave_n := 0                      ## waves since arrival (processions start at PROCESSION.minWave)
	var since_arrival := 0.0             ## s a hero has been in the area (Wave Speed ramps in over DmEnemyStats.RAMP_S, like the sim's ramp_tier)
	var heroes: Array = []               ## the living heroes standing in it this tick (refilled by the director, never allocated per tick)

	## No hero in the area: the next visit starts over.
	func rest(first_wave_delay: float) -> void:
		wave_t = first_wave_delay
		since_arrival = 0.0
		first_wave = true
		wave_n = 0


var game: Node                          ## DmNextGame
var core_host: DmCoreHost:
	set(host):
		core_host = host
		if host != null and not host.enemy_died.is_connected(_on_enemy_died):
			host.enemy_died.connect(_on_enemy_died)   # every death, by core id, for the open Grave Surge
var area_id: String:                    ## the area the director serves (the ground in hand)
	get: return _g.area_id
	set(v): _g.area_id = v
var enabled: bool = true
var wave_interval: float:
	get: return _g.wave_interval
	set(v): _g.wave_interval = v
var wave_size: int:
	get: return _g.wave_size
	set(v): _g.wave_size = v
var cap: int:
	get: return _g.cap
	set(v): _g.cap = v
var first_wave_delay: float = 1.0
var kinds: Array:                       ## [{id, weight}] the core can run
	get: return _g.kinds
	set(v): _g.kinds = v
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

var _g := Ground.new()                  ## the ground in hand: the area the director serves, whose clock `_physics_process` runs first
var _extra: Array[Ground] = []          ## host, in a party: a ground for every other combat area a member stands in (each served after the one in hand; dropped EMPTY_CLEAR_S after its last member leaves)
var _since_arrival: float:              ## s a hero has been in the ground in hand (tests set it to put the Wave Speed ramp in)
	get: return _g.since_arrival
	set(v): _g.since_arrival = v
var _combat_ground: Dictionary = {}     ## area id -> whether it is a combat ground (`_is_combat`)
var follow_areas := true                ## host: when no hero is in `area_id`, move to the combat area one is in (DmNextGame: every area has a roster)
var surge: DmGraveSurge                 ## Grave Surges (next/areas/dm_grave_surge.gd), host; its clock runs from `_physics_process` while a hero is in a combat area
var off: Dictionary = {}                ## defs the director leaves out as if the core did not run them (def id -> true; client/tests/core_kinds.gd leaves out the Bellringers' censer with it)
var _vanguard := false                  ## this wave carries the Elite Vanguard (every other wave): its first plain pick is an elite
var _pending: Array[Dictionary] = []    ## host: wave spawns decided (kind, position, scaling) but not yet made, drained SPAWNS_PER_TICK per tick (a Grave Surge's carry its serial in "surge")
var _staging := false                   ## spawn_wave (or a Grave Surge's wave) is queueing its bodies
var _surge_serial := 0                  ## a Grave Surge is queueing its wave: the serial each queued body carries, so `_make_next` can hand the surge the body's core id (0 = an ordinary wave's)


func _ready() -> void:
	rng.randomize()
	surge = DmGraveSurge.new(self)
	configure_area(area_id)


## Wave Speed (the sim's formulas): the wave timer is divided by 1 + 0.12 d, a wave holds more (sizeMult), the area holds more (capMult).
## Enemy hp / damage scale at spawn from the ramped tier. Every ground the director serves takes the tier.
func set_wave_tier(tier: float) -> void:
	wave_tier = tier
	_apply_tier(_g)
	for gr in _extra:
		_apply_tier(gr)


func _apply_tier(gr: Ground) -> void:
	var m := DmWaveUpgrades.wave_modifiers(wave_tier)
	gr.wave_interval = float(gr.base[0]) * float(m["intervalMult"])
	gr.wave_size = DmMath.js_round(float(gr.base[1]) * float(m["sizeMult"]) * size_extra)
	gr.cap = DmMath.js_round(float(gr.base[2]) * float(m["capMult"]))


## The director serves this area from now on (its clock starts over; the party's other grounds are left as they are).
func configure_area(id: String) -> void:
	_configure(_g, id)


func _configure(gr: Ground, id: String) -> void:
	gr.area_id = id
	var def: Dictionary = DmContent.area(id)
	gr.wave_interval = float(def.get("waveIntervalMs", 6500)) / 1000.0
	gr.wave_size = int(def.get("waveSize", 9))
	gr.cap = int(def.get("cap", 28))
	gr.base = [gr.wave_interval, gr.wave_size, gr.cap]
	if wave_tier != 0.0 or size_extra != 1.0:
		_apply_tier(gr)
	gr.kinds.clear()
	for e in def.get("enemies", []):
		if makes(String(e["id"])):
			gr.kinds.append({"id": String(e["id"]), "weight": float(e["weight"])})
	gr.wave_t = first_wave_delay
	gr.first_wave = true
	gr.wave_n = 0


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
	var other := _sort_heroes()
	if _g.heroes.is_empty() and follow_areas and other != "" and other != area_id:
		clear_area(area_id)   # the old ground's queued spawns; a Depths run's dead are the Depths'
		if surge != null:
			surge.reset()
		_follow(other)
		area_followed.emit(other)
		_sort_heroes()
	var heroes := _g.heroes
	if heroes.is_empty():
		_g.rest(first_wave_delay)
		_g.empty_t += delta
		if _g.empty_t > EMPTY_CLEAR_S and _g.empty_t - delta <= EMPTY_CLEAR_S:   # once, as the time runs out
			clear_area(area_id)
		if surge != null:
			surge.reset()
	else:
		_wave_clock(heroes, delta)
		if surge != null:
			surge.update(delta, heroes)
	if not _extra.is_empty():
		_serve_extra_grounds(delta)


## One tick of the wave clock of the ground in hand, with the heroes standing in it: the wave when its time is up.
func _wave_clock(heroes: Array, delta: float) -> void:
	_g.empty_t = 0.0
	_g.since_arrival += delta
	_g.wave_t -= delta
	if _g.wave_t > 0.0:
		return
	_g.wave_t = wave_interval
	if _g.first_wave:
		_g.first_wave = false
		spawn_wave(heroes, DmMath.js_round(float(_g.base[1]) * 1.3))
		return
	_g.wave_n += 1
	_vanguard = _g.wave_n % 2 == 1 and milestone("vanguard")
	var theme: Variant = _roll_theme()
	if theme == null:
		spawn_wave(heroes)
	else:
		var th: Dictionary = theme
		var made := spawn_wave(heroes, maxi(1, DmMath.js_round(float(wave_size) * float(th["sizeMult"]))), th["roster"], String(th["lead"]) if th.get("lead") != null else "")
		if made > 0:
			procession.emit(th)
	_vanguard = false


## Party: every other combat area a member stands in has waves of its own. Each ground takes its turn as the one in hand, so a wave there is decided, sized, scaled and placed by the same code as the director's own area's
## (its roster, cap, level, Wave Speed ramp, processions and elites), around the members standing there. A ground nobody has stood in for EMPTY_CLEAR_S is cleared (as the director's own is) and dropped.
func _serve_extra_grounds(delta: float) -> void:
	var main := _g
	var i := _extra.size() - 1
	while i >= 0:
		var gr: Ground = _extra[i]
		if gr.heroes.is_empty():
			gr.rest(first_wave_delay)
			gr.empty_t += delta
			if gr.empty_t > EMPTY_CLEAR_S:
				clear_area(gr.area_id)
				_extra.remove_at(i)
		else:
			_g = gr
			_wave_clock(gr.heroes, delta)
			_g = main
		i -= 1


## Sorts the living heroes into the grounds they stand in: the one in hand (`_g.heroes`) and, in a party, a ground of its own for every other combat area a member stands in (made the first
## time one does). Returns the first other combat area a hero stands in ("" if none): where the director moves when nobody is in its own.
func _sort_heroes() -> String:
	var bodies: Array = game.session.get_bodies()
	var party := follow_areas and bodies.size() > 1
	_g.heroes.clear()
	for gr in _extra:
		gr.heroes.clear()
	var first := ""
	for b in bodies:
		var hb := b as DmHeroBody
		if hb == null or not hb.alive:
			continue
		var a: String = game.world.area_at(hb.position.x, hb.position.z)
		if a == _g.area_id:
			_g.heroes.append(hb)
		elif a != "" and _is_combat(a):
			if first == "":
				first = a
			if party:
				_ground_of(a).heroes.append(hb)
	return first


## The extra ground of a combat area (made and configured on the first member there).
func _ground_of(area: String) -> Ground:
	for gr in _extra:
		if gr.area_id == area:
			return gr
	var made := Ground.new()
	_configure(made, area)
	_extra.append(made)
	return made


## The director moves to a combat area a hero stands in: the ground a member already holds there (its clock running) becomes the one in hand, else the director is configured for the area.
func _follow(area: String) -> void:
	for i in _extra.size():
		if _extra[i].area_id == area:
			_g = _extra[i]
			_extra.remove_at(i)
			return
	configure_area(area)


## Every body of the core that died, by its id: a Grave Surge counts the ones it brought up (connected when `core_host` is set).
func _on_enemy_died(id: int, _def: String, _level: int, _elite: bool, _area: String, _source: int, _x: float, _z: float) -> void:
	if surge != null:
		surge.on_enemy_died(id)


## Whether an area is a combat ground (neither safe nor an instance); read from the content once per area.
func _is_combat(id: String) -> bool:
	if not _combat_ground.has(id):
		_combat_ground[id] = not _is_safe_or_instance(id)
	return _combat_ground[id]


static func _is_safe_or_instance(id: String) -> bool:
	var def: Dictionary = DmContent.area(id)
	return bool(def.get("safe", true)) or bool(def.get("instance", false))


## The sim's procession: from wave PROCESSION.minWave on, a PROCESSION.chance of waves is themed (a roster, sometimes a lead, a size).
func _roll_theme() -> Variant:
	var themes: Array = DmSimData.WAVE_THEMES.get(area_id, [])
	if themes.is_empty() or _g.wave_n < int(DmSimData.PROCESSION["minWave"]) or rng.randf() >= float(DmSimData.PROCESSION["chance"]):
		return null
	return themes[rng.randi() % themes.size()]


## How many more bodies the ground in hand may take: under its area's cap and under the global limit (`GLOBAL_ENEMY_CAP`, the dying and the queued count). With one ground in play every living body counts against the cap,
## as it always did. With several (a party apart) the global limit is shared: each ground holds at most its equal share of it, and counts only the bodies standing in its own area and its own queued ones.
func _room() -> int:
	var limit := enemy_limit if enemy_limit > 0 else int(DmSimData.GLOBAL_ENEMY_CAP)
	var queued := _pending.size()
	var room := limit - enemy_total() - queued
	if _extra.is_empty():
		return mini(cap - alive_count() - queued, room)
	var served := 1
	for gr in _extra:
		if not gr.heroes.is_empty():
			served += 1
	queued = 0
	for d in _pending:
		if d["area"] == area_id:
			queued += 1
	return mini(mini(cap, limit / served) - _alive_in(area_id) - queued, room)


## The living bodies standing in an area's ground (a dead one does not count): one pass over the core's rows, only asked when a wave is decided.
func _alive_in(area: String) -> int:
	var rect: Dictionary = DmContent.area(area)["rect"]
	var x0 := float(rect["x0"])
	var x1 := float(rect["x1"])
	var z0 := float(rect["z0"])
	var z1 := float(rect["z1"])
	var rows: PackedFloat32Array = core_host.core.enemy_rows()   # 7 numbers a body: id, def, x, z, hp, max hp, state
	var dead := float(DmCoreEvents.State.DEAD)
	var n := 0
	var i := 0
	while i < rows.size():
		var x := rows[i + 2]
		var z := rows[i + 3]
		if rows[i + 6] != dead and x >= x0 and x <= x1 and z >= z0 and z <= z1:
			n += 1
		i += 7
	return n


## A wave of `count` (default: the wave size) climbing in around the heroes. `roster` ([{id, weight}], default the area's) and `lead` (the first
## group's kind) are a procession's. Returns how many spawned.
func spawn_wave(heroes: Array, count: int = -1, roster: Array = [], lead: String = "") -> int:
	if kinds.is_empty() or heroes.is_empty():
		return 0
	var n := mini(wave_size if count < 0 else count, _room())
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
