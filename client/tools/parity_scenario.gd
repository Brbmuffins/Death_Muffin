extends SceneTree
## The seeded scenario comparison, this side (ROADMAP Gate B, native/README.md "Proof of same game"): the rebuilt client plays the scenario below and writes its metrics
## as JSON. `godot/tests/parity/scenario.gd` plays the same scenario in today's game with the same arguments and the same keys; `tools/rebuild/compare-scenarios.mjs` runs both
## for several seeds and tabulates them.
##
## The scenario: the Hollow Graves, one Gravecaller (discipline 2) at a fixed level on the kit's default loadout, Easy difficulty and Easy auto combat ON (today's DmAutoCombat /
## DmAutoDodge decisions, which move the hero too), the area's normal waves from the director (no held counts: cap 28, 9 a wave every 6.5 s, elites at 3.5 %, processions), the
## director's random stream seeded, no rewards (the kill credit is cut off from them and the Omen pinned to none, as today's side does) and the in-memory mock. The hero cannot die: his health is refilled when a blow lands, and what the blow cost is counted.
## A hero who stands against the graves' tombstones without fighting (under STALL_M metres and STALL_CASTS casts in STALL_S seconds) is set back at the door, as a player would walk him out,
## and `unsticks` counts it (both games do it at the same places). `--seconds` of game time are played (physics ticks, so `--fixed-fps 60` runs it faster than real time without changing it).
##   nice -n 10 godot --headless --fixed-fps 60 --path client --script res://tools/parity_scenario.gd -- --seed=1 --seconds=180 --out=/tmp/client-1.json [--level=10] [--difficulty=easy]
## Everything is read from the host's signals and the caster's events (the tool adds no work to the game's ticks beyond its own counters; the legion is sampled once a tick by the tool).

const AREA := "graves"
const DISCIPLINE := 2
const SPAWN_X := 0.0   ## where the hero stands when the waves begin: the Graves' door, the same point on both sides
const SPAWN_Z := 1.0
const STALL_S := 10      ## a hero who moved less than STALL_M in STALL_S seconds and cast less than STALL_CASTS times is stuck against the graves, not fighting: he is set back at the door
const STALL_M := 1.0
const STALL_CASTS := 4

var seed_n := 1
var seconds := 180.0
var level := 10
var difficulty := "easy"
var out_path := ""
var trace_s := 0.0   ## --trace=<s>: a line of the scenario's state every <s> seconds of game time (diagnosis)

var g: DmNextGame
var host: DmCoreHost
var hero: DmHeroBody
var caster: Node

var m_spawned := 0
var m_spawned_by := {}
var m_elite_spawned := 0
var m_kills := 0
var m_kills_by := {}
var m_elite_kills := 0
var m_hero_damage := 0.0
var m_thrall_damage := 0.0
var m_other_damage := 0.0
var m_taken := 0.0
var m_blows := 0
var m_raw_blows := 0
var m_raw_damage := 0.0
var m_hero_deaths := 0
var m_thralls_raised := 0
var m_thralls_lost := 0
var m_thrall_hurt := 0.0
var m_th_hurt_by := {}    ## enemy def -> [blows, damage] on the hero's thralls
var m_th_lost := {"reason": {}, "kind": {}, "killer": {}}   ## how the thralls were lost: why, which kind, and the def of the last enemy that hurt it
var m_casts := {}
var m_ttk: Array = []
var m_ttk_by := {}
var m_reach_by := {}
var m_live_sum := 0.0
var m_at_cap := 0
var m_places_sum := 0.0
var m_samples := 0
var m_levels := {}
var m_unsticks: Array = []   ## [t, x, z] of each time the hero was set back at the door
var _hist := PackedVector2Array()
var _cast_hist := PackedInt32Array()

var _born := {}           ## enemy id -> physics frame of its spawn event
var _def := {}            ## enemy id -> its def (the damaged event does not carry it)
var _reached := {}        ## enemy id -> true once it has been hurt (the first hurt ends "reach": the time a body takes to meet the fight)
var _thrall_ids := {}     ## thrall id -> true while it is a thrall of the hero (source classification)
var _kind_of := {}        ## enemy id -> def, for the whole run (the killer of a thrall may be gone)
var _zone_src := {}       ## hostile zone id -> the enemy that made it (a cloud's or a pool's damage is that enemy's, as today's zone node says)


func _arg(name: String, default: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return default


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed_n = int(_arg("seed", "1"))
	seconds = float(_arg("seconds", "180"))
	level = int(_arg("level", "10"))
	difficulty = _arg("difficulty", "easy")
	out_path = _arg("out", "")
	trace_s = float(_arg("trace", "0"))
	seed(seed_n)   # the global stream too (rites roll crits and spread with randf)
	var wall0 := Time.get_ticks_msec()
	var mock := DmOffline.make_mock("")   # memory only: no file, no server
	var api := DmOffline.make_api(mock)
	var reg := await api.register("parity", "p@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(DISCIPLINE)
	DmDevMock.set_level(mock, ch.data, level)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["graves"], "name": "parity", "hud": false, "audio": false, "waves": false, "persist": false, "omen": {}, "difficulty": difficulty, "seed": seed_n})
	host = g.core_host
	hero = g.local_body()
	caster = hero.get_node("Rites")
	for i in 30:
		await process_frame
	# the scenario's rules: Easy, Easy auto combat open, the director seeded
	g.kill_credited.disconnect(g.rewards._on_kill_credited)   # no kill reaches the rewards: no XP, no Soul Harvest, no Kill Chain, no loot (as today's side)
	g.input.auto.gate_probe = func() -> bool: return true
	g.director.off["censer"] = true                           # no censer for the Bellringers' procession (today's side leaves it out: its scene is dropped), so both sides play the same rules
	g.director.difficulty = difficulty
	g.director.rng.seed = seed_n
	_observe()
	var hero_start := hero.position
	hero.teleport(Vector3(SPAWN_X, 0.0, SPAWN_Z))
	g.camera.snap(hero.position)
	var setup := {"hero_start": [hero_start.x, hero_start.z], "hero_max_hp": hero.max_hp, "hero_level": float(caster.p["stats"]["level"]), "thrall_cap": _thrall_cap(), "hero_position": [hero.position.x, hero.position.z],
		"director": {"cap": g.director.cap, "wave_size": g.director.wave_size, "wave_interval_s": g.director.wave_interval, "kinds": g.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))}}
	var start := Engine.get_physics_frames()
	var end := start + int(seconds * 60.0)
	g.director.enabled = true
	while Engine.get_physics_frames() < end:
		await physics_frame
		_sample()
		if (Engine.get_physics_frames() - start) % 60 == 0:
			_check_stall((Engine.get_physics_frames() - start) / 60)
		if trace_s > 0.0 and (Engine.get_physics_frames() - start) % int(trace_s * 60.0) == 0:
			print("TRACE t=%d pos=(%.1f,%.1f) alive=%d kills=%d thralls=%d hp=%.0f/%.0f casts=%s nearest=%s auto=%s" % [(Engine.get_physics_frames() - start) / 60, hero.position.x, hero.position.z,
				host.alive_count(), m_kills, caster.thralls().count(), hero.hp, hero.max_hp, str(m_casts), _nearest(), str(g.input.auto.stats)])
	var wall := float(Time.get_ticks_msec() - wall0) / 1000.0
	_write(setup, wall)
	quit(0)


## Trace only: the nearest living enemy to the hero, "distance/state".
func _nearest() -> String:
	var ids: PackedInt32Array = host.core.enemy_ids()
	var pos: PackedFloat32Array = host.core.enemy_positions()
	var states: PackedInt32Array = host.core.enemy_states()
	var best := INF
	var bs := -1
	for i in ids.size():
		if states[i] == DmCoreEvents.State.DEAD:
			continue
		var d := Vector2(pos[i * 3] - hero.position.x, pos[i * 3 + 1] - hero.position.z).length()
		if d < best:
			best = d
			bs = states[i]
	return "%.1f/%d" % [best, bs]


func _thrall_cap() -> int:
	return int(hero.mods.get("thrallCap", 0))


## Signals only: the host's events (spawned, damaged, died, thralls), the hero's hurt and the caster's cast events.
func _observe() -> void:
	host.enemy_spawned.connect(func(id: int, def: String, lv: int, elite: bool, _a: String, _af: int, _x: float, _z: float, _hp: float) -> void:
		m_spawned += 1
		m_spawned_by[def] = int(m_spawned_by.get(def, 0)) + 1
		m_levels[lv] = int(m_levels.get(lv, 0)) + 1
		if elite:
			m_elite_spawned += 1
		_born[id] = Engine.get_physics_frames()
		_def[id] = def
		_kind_of[id] = def)
	host.enemy_damaged.connect(func(id: int, source: int, amount: float, _hp: float) -> void:
		if _born.has(id) and not _reached.has(id):
			_reached[id] = true
			var kind: String = _def[id]
			if not m_reach_by.has(kind):
				m_reach_by[kind] = []
			m_reach_by[kind].append(snappedf(float(Engine.get_physics_frames() - int(_born[id])) / 60.0, 0.1))
		if source == hero.core_id:
			m_hero_damage += amount
		elif _thrall_ids.has(source):
			m_thrall_damage += amount
		else:
			m_other_damage += amount)
	host.enemy_died.connect(func(id: int, def: String, _lv: int, elite: bool, _a: String, _source: int, _x: float, _z: float) -> void:
		m_kills += 1
		m_kills_by[def] = int(m_kills_by.get(def, 0)) + 1
		if elite:
			m_elite_kills += 1
		if _born.has(id):
			_def.erase(id)
			_reached.erase(id)
			var t := float(Engine.get_physics_frames() - int(_born[id])) / 60.0
			m_ttk.append(t)
			if not m_ttk_by.has(def):
				m_ttk_by[def] = []
			m_ttk_by[def].append(t)
			_born.erase(id))
	host.thrall_raised.connect(func(id: int, _k: String, owner: int, _s: int, _e: bool, _c: bool, _x: float, _z: float, _y: float, _hp: float) -> void:
		if owner == hero.core_id:
			m_thralls_raised += 1
			_thrall_ids[id] = true)
	host.zone.connect(func(id: int, _kind: int, source: int, _x: float, _z: float, _r: float, _s: float) -> void: _zone_src[id] = source)
	host.thrall_damaged.connect(func(id: int, source: int, amount: float, _hp: float) -> void:
		if _thrall_ids.has(id):
			m_thrall_hurt += amount
			_tally2(m_th_hurt_by, String(_kind_of.get(int(_zone_src.get(source, source)), "other")), amount))
	host.thrall_died.connect(func(_id: int, reason: String, owner: int, kind: String, src: int, _x: float, _z: float) -> void:
		if owner == hero.core_id:
			m_thralls_lost += 1
			_tally(m_th_lost["reason"], reason)
			_tally(m_th_lost["kind"], kind)
			_tally(m_th_lost["killer"], String(_kind_of.get(int(_zone_src.get(src, src)), "other"))))
	hero.hurt.connect(func(amount: float, _src: Variant) -> void:
		m_taken += amount
		m_blows += 1
		hero.heal(1.0e9))
	g.hero_hit.connect(func(_id: int, _kind: String, damage: float) -> void:
		m_raw_blows += 1
		m_raw_damage += damage)
	g.hero_died.connect(func(_b: DmHeroBody) -> void: m_hero_deaths += 1)
	caster.event_played.connect(func(ev: Dictionary) -> void:
		if String(ev.get("t", "")) == "cast":
			var r := String(ev.get("rite", ""))
			m_casts[r] = int(m_casts.get(r, 0)) + 1)


## Once a second. Easy auto combat steers straight at the nearest enemy, and the graves hold pockets of tombstones (around (3.5, -3.5) and by the door) where that walk ends
## for good: the hero stands against them for the rest of the run and nothing is fought. Both games do it, and it makes a run's kills swing by half, so the scenario sets such a
## hero back at the door (a player would walk him out) and counts it: `unsticks` is a result too.
func _check_stall(t: int) -> void:
	if not hero.alive:
		_hist.clear()
		_cast_hist.clear()
		return
	var casts: int = m_casts.values().reduce(func(a, b): return a + b, 0)
	_hist.append(Vector2(hero.position.x, hero.position.z))
	_cast_hist.append(casts)
	if _hist.size() <= STALL_S:
		return
	if _hist.size() > STALL_S + 1:
		_hist.remove_at(0)
		_cast_hist.remove_at(0)
	if _hist[STALL_S].distance_to(_hist[0]) < STALL_M and _cast_hist[STALL_S] - _cast_hist[0] < STALL_CASTS:
		m_unsticks.append([t, snappedf(hero.position.x, 0.1), snappedf(hero.position.z, 0.1)])
		hero.teleport(Vector3(SPAWN_X, 0.0, SPAWN_Z))
		_hist.clear()
		_cast_hist.clear()


func _tally(d: Dictionary, key: String) -> void:
	d[key] = int(d.get(key, 0)) + 1


func _tally2(d: Dictionary, key: String, amount: float) -> void:
	if not d.has(key):
		d[key] = [0, 0.0]
	d[key][0] += 1
	d[key][1] += amount


## Once a tick: how many thralls the legion holds and whether it is full (the tool's own reads of the legion; the game does nothing extra).
func _sample() -> void:
	var legion = caster.thralls()
	var n: int = legion.count()
	var places: float = legion.places_used()
	m_live_sum += n
	m_places_sum += places
	if places >= float(_thrall_cap()) - 0.0001:
		m_at_cap += 1
	m_samples += 1


static func _pct(sorted: Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	var i := (sorted.size() - 1) * p
	var lo := int(floor(i))
	var hi := int(ceil(i))
	return float(sorted[lo]) + (float(sorted[hi]) - float(sorted[lo])) * (i - lo)


static func _ttk_stats(arr: Array) -> Dictionary:
	var s := arr.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += float(v)
	return {"n": s.size(), "median": _pct(s, 0.5), "p25": _pct(s, 0.25), "p75": _pct(s, 0.75), "mean": sum / maxf(1.0, float(s.size()))}


func _write(setup: Dictionary, wall: float) -> void:
	var by_kind := {}
	var samples := {}
	for k in m_ttk_by:
		by_kind[k] = _ttk_stats(m_ttk_by[k])
		samples[k] = m_ttk_by[k].map(func(t: float) -> float: return snappedf(t, 0.1))
	var res := {
		"side": "client", "seed": seed_n, "seconds": seconds, "level": level, "difficulty": difficulty, "area": AREA, "discipline": DISCIPLINE, "setup": setup,
		"metrics": {
			"kills": m_kills, "kills_by_kind": m_kills_by, "elite_kills": m_elite_kills,
			"spawned": m_spawned, "spawned_by_kind": m_spawned_by, "elite_spawned": m_elite_spawned, "alive_at_end": _born.size(),
			"hero_damage": m_hero_damage, "thrall_damage": m_thrall_damage, "other_damage": m_other_damage,
			"damage_taken": m_taken, "blows_taken": m_blows, "blows_landed": m_raw_blows, "blow_damage": m_raw_damage, "hero_deaths": m_hero_deaths,
			"ttk": _ttk_stats(m_ttk), "ttk_by_kind": by_kind, "ttk_samples_by_kind": samples, "first_hurt_by_kind": m_reach_by,
			"thrall_damage_taken": m_thrall_hurt, "thrall_hurt_by_def": m_th_hurt_by, "thralls_lost_by": m_th_lost, "thralls_raised": m_thralls_raised, "thralls_lost": m_thralls_lost,
			"thrall_mean_live": m_live_sum / maxf(1.0, float(m_samples)), "thrall_mean_places": m_places_sum / maxf(1.0, float(m_samples)),
			"thrall_at_cap_frac": float(m_at_cap) / maxf(1.0, float(m_samples)), "thrall_cap": _thrall_cap(),
			"casts": m_casts, "casts_total": m_casts.values().reduce(func(a, b): return a + b, 0),
			"enemy_levels": m_levels, "unsticks": m_unsticks.size(), "unstick_at": m_unsticks,
		},
		"wall_s": wall,
	}
	var text := JSON.stringify(res, "  ")
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
			f.close()
		else:
			printerr("parity_scenario: cannot write ", out_path)
	print("PARITY client seed=%d kills=%d spawned=%d hero_dmg=%.0f thrall_dmg=%.0f taken=%.0f ttk_median=%.2f thralls_live=%.2f at_cap=%.2f wall=%.1fs" % [
		seed_n, m_kills, m_spawned, m_hero_damage, m_thrall_damage, m_taken, _ttk_stats(m_ttk)["median"], m_live_sum / maxf(1.0, float(m_samples)), float(m_at_cap) / maxf(1.0, float(m_samples)), wall])
