extends SceneTree
## The seeded scenario comparison, this side (ROADMAP Gate B, native/README.md "Proof of same game"): today's game plays the scenario below and writes its metrics as JSON.
## `client/tools/parity_scenario.gd` plays the same scenario in the rebuilt client with the same arguments and the same keys; `tools/rebuild/compare-scenarios.mjs` runs both for
## several seeds and tabulates them. A probe like tests/perf/fight_breakdown.gd, not a suite (no run.gd: run-all-tests.sh does not pick it up).
##
## The scenario: the Hollow Graves, one Gravecaller (discipline 2) at a fixed level on the kit's default loadout, Easy difficulty and Easy auto combat ON (DmAutoCombat /
## DmAutoDodge decide, and move the hero too), the area's normal waves from the director (cap 28, 9 a wave every 6.5 s, elites at 3.5 %, processions), the director's random
## stream seeded, no rewards or backend (the in-memory mock). The hero cannot die: his health is refilled when a blow lands, and what the blow cost is counted.
## `--discipline=<index>` (1 Ossuary, 2 Gravecaller, 3 Mourner, 4 Rotweaver, 11 the Reaper) and `--area=<id>` (any hunting ground whose kinds the client's core runs) change the hero and the
## ground; the defaults are the scenario above. In another area the hero's seal is broken (and the doors of the area stay shut, as the client loads the one area), he stands where a waystone
## sets a traveller down (the waystone's place, 1.6 m on), and the director's waves are that area's: its roster, cap, size and pace, its elites, its processions and its level (fixed by the
## area, or the hero's own where the area scales).
## A hero who stands against the graves' tombstones without fighting (under STALL_M metres and STALL_CASTS casts in STALL_S seconds) is set back at the door, as a player would walk him out,
## and `unsticks` counts it (both games do it at the same places). `--seconds` of game time are played (physics ticks, so `--fixed-fps 60` runs it faster than real time without changing it).
##   nice -n 10 godot --headless --fixed-fps 60 --path godot --script res://tests/parity/scenario.gd -- --seed=1 --seconds=180 --out=/tmp/today-1.json [--level=10] [--difficulty=easy] [--discipline=2] [--area=graves]
##
## What the scenario switches off in today's game so both sides play the same rules (the client has none of these yet; native/README.md "Differences from today's game"):
##   - the rewards: the kill-credit consumers are cut off (no XP and level-ups mid-run, no Soul Harvest free casts, no Kill Chain), the Omen is pinned to none (opts.omen)
##     (the Reaper's souls come from those kills: this tool banks them for her instead, one for each enemy that dies within KILL_REWARD_RANGE, the same rule on both sides)
##   - Grave Surges (the director's `surge`), and the Bellringers' censer (the client's director skips a def its core does not run, as one without a scene was)
##   - the wall clock of Easy auto combat: DmNextInput ticks it with Time.get_ticks_msec(), which a faster-than-real-time run stretches; this tool ticks it on the physics
##     clock, as the client does (DmNextAutoCombat.clock_ms), so the cadence is the same at any speed
## Everything is read from signals (the director's, the enemies', the thralls', the hero's, the caster's); the legion is sampled once a tick by the tool. Game code is untouched.

const GRAVES_X := 0.0   ## where the hero stands when the waves begin in the Hollow Graves: the Graves' door, the same point on both sides
const GRAVES_Z := 1.0
const REAPER_CASTS := ["sweep", "throw", "reap", "walk", "burst", "spin", "release", "harvest", "weave"]   ## the event types that start one of the Reaper's rites
const REAPER_RITES := ["scythe_sweep", "scythe_throw", "reap", "wraith_walk", "soul_burst", "harvest_spin", "unleash_souls", "soul_harvest", "scythe_weave"]
const KILL_REWARD_RANGE := 38.0   ## a kill pays a hero within this many metres (DmGameRewards.KILL_REWARD_RANGE, gameplay_killCredit.json)
const WAYSTONE_STEP := 1.6   ## a waystone sets a traveller down this far (z) from its own place (DmChapterhouse.travel)
const STALL_S := 10      ## a hero who moved less than STALL_M in STALL_S seconds and cast less than STALL_CASTS times is stuck against the graves, not fighting: he is set back at the door
const STALL_M := 1.0
const STALL_CASTS := 4

var area := "graves"
var discipline := 2
var spawn_x := GRAVES_X   ## where the hero starts and where a stuck one is set back: the Graves' door, or the area's waystone
var spawn_z := GRAVES_Z
var seed_n := 1
var seconds := 180.0
var level := 10
var difficulty := "easy"
var out_path := ""
var trace_s := 0.0   ## --trace=<s>: a line of the scenario's state every <s> seconds of game time (diagnosis)

var g: DmNextGame
var hero: DmHeroBody
var caster: DmRiteCaster
var auto: DmNextAutoCombat

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

var _born := {}      ## enemy instance id -> physics frame of its spawn
var _th_last := {}   ## thrall instance id -> def of the last enemy that hurt it
var _reached := {}   ## enemy instance id -> true once it has been hurt (the first hurt ends "reach": the time a body takes to meet the fight)


func _arg(name: String, default: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return default


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	seed_n = int(_arg("seed", "1"))
	area = _arg("area", "graves")
	discipline = int(_arg("discipline", "2"))
	seconds = float(_arg("seconds", "180"))
	level = int(_arg("level", "10"))
	difficulty = _arg("difficulty", "easy")
	out_path = _arg("out", "")
	trace_s = float(_arg("trace", "0"))
	OS.set_environment("DM_SYNC_NAV", "1")   # navigation merges in step with game time (world_builder.gd), as the suites run it under --fixed-fps
	seed(seed_n)   # the global stream too (rites and thralls roll with randf)
	var wall0 := Time.get_ticks_msec()
	var mock := DmOffline.make_mock("")   # memory only: no file, no server
	var api := DmOffline.make_api(mock)
	var reg := await api.register("parity", "p@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(discipline)
	ch.data["level"] = level
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(ch.data, api, {"name": "parity", "hud": false, "audio": false, "waves": false, "persist": false, "dressing": false, "warmup": false, "omen": {}, "difficulty": difficulty})
	hero = g.local_body()
	caster = hero.get_node("Rites") as DmRiteCaster
	for i in 30:
		await process_frame
	# the scenario's rules
	g.enemy_spawned.disconnect(g.rewards.watch_enemy)   # no kill reaches the rewards: no XP, no Soul Harvest, no Kill Chain, no loot
	g.director.surge = null                             # no Grave Surges (the client has none)
	g.director._scene_cache["censer"] = null            # no censer for the Bellringers' procession (the client's core does not run it)
	g.input.set_physics_process(false)                  # the tool ticks Easy auto combat on the physics clock (below)
	auto = DmNextAutoCombat.new()                       # fresh: the input's own ticks ran it on the wall clock while the game started
	auto.gate_probe = func() -> bool: return true
	auto.setup(g, g.input)
	g.input.auto = auto
	g.director.difficulty = difficulty
	g.director.rng.seed = seed_n
	_place_area()
	_observe()
	var hero_start := hero.position
	hero.teleport(Vector3(spawn_x, 0.0, spawn_z))
	g.camera.snap(hero.position)
	var setup := {"hero_start": [hero_start.x, hero_start.z], "hero_max_hp": hero.max_hp, "hero_level": float(caster.p["stats"]["level"]), "thrall_cap": _thrall_cap(), "hero_position": [hero.position.x, hero.position.z],
		"director": {"cap": g.director.cap, "wave_size": g.director.wave_size, "wave_interval_s": g.director.wave_interval, "kinds": g.director.kinds.map(func(k: Dictionary) -> String: return String(k["id"]))}}
	var start := Engine.get_physics_frames()
	var end := start + int(seconds * 60.0)
	g.director.enabled = true
	while Engine.get_physics_frames() < end:
		await physics_frame
		auto.tick(float(Engine.get_physics_frames()) * 1000.0 / 60.0)
		_sample()
		if (Engine.get_physics_frames() - start) % 60 == 0:
			_check_stall((Engine.get_physics_frames() - start) / 60)
		if trace_s > 0.0 and (Engine.get_physics_frames() - start) % int(trace_s * 60.0) == 0:
			print("TRACE t=%d pos=(%.1f,%.1f) alive=%d kills=%d thralls=%d hp=%.0f/%.0f casts=%s auto=%s last=%s" % [(Engine.get_physics_frames() - start) / 60, hero.position.x, hero.position.z,
				g.director.alive_count(), m_kills, caster.thralls().count(), hero.hp, hero.max_hp, str(m_casts), str(auto.stats), str(auto.last_action)])
	var wall := float(Time.get_ticks_msec() - wall0) / 1000.0
	_write(setup, wall)
	quit(0)


## Another hunting ground than the Graves: its seal is broken and its doors are shut (the client loads the one area; a door open to the Graves would let a body walk there), the
## hero's arrival point is the area's waystone, and the director deals the area's waves. The Graves are left exactly as they were.
func _place_area() -> void:
	if area == "graves":
		return
	var def: Dictionary = DmContent.area(area)
	var b: DmWorldBuilder = g.world.builder
	b.set_unlocked([area])
	for d: Dictionary in DmContent.get_export("areas", "DOORS"):
		if String(d["a"]) == area or String(d["b"]) == area:
			b.set_door_open(String(d["id"]), false, true)
	for it: Dictionary in def["interactables"]:
		if String(it["kind"]) == "waystone":
			spawn_x = float(it["x"])
			spawn_z = float(it["z"]) + WAYSTONE_STEP
	g.director.configure_area(area)


func _thrall_cap() -> int:
	return int(hero.mods.get("thrallCap", 0))


## Signals only: the director's and the enemies' (spawned, damaged, died, struck), the legion's (raised, died), the hero's hurt and the caster's cast events.
func _observe() -> void:
	g.enemy_spawned.connect(func(e: DmEnemy) -> void:
		var def := e.def_id
		m_spawned += 1
		m_spawned_by[def] = int(m_spawned_by.get(def, 0)) + 1
		var lv := int(e.get_meta(&"dm_level", 1))
		m_levels[lv] = int(m_levels.get(lv, 0)) + 1
		if e.elite:
			m_elite_spawned += 1
		_born[e.get_instance_id()] = Engine.get_physics_frames()
		e.damaged.connect(func(amount: float, _hp: float, from: Node) -> void:
			var eid := e.get_instance_id()
			if _born.has(eid) and not _reached.has(eid):
				_reached[eid] = true
				if not m_reach_by.has(def):
					m_reach_by[def] = []
				m_reach_by[def].append(snappedf(float(Engine.get_physics_frames() - int(_born[eid])) / 60.0, 0.1))
			if from is DmHeroBody:
				m_hero_damage += amount
			elif from is DmThrall:
				m_thrall_damage += amount
			else:
				m_other_damage += amount)
		e.struck.connect(func(target: Node3D, damage: float) -> void:
			if target is DmHeroBody:
				m_raw_blows += 1
				m_raw_damage += damage))
	g.director.enemy_died.connect(func(e: DmEnemy) -> void:
		_bank_soul(e.position.x, e.position.z)
		var def := e.def_id
		m_kills += 1
		m_kills_by[def] = int(m_kills_by.get(def, 0)) + 1
		if e.elite:
			m_elite_kills += 1
		var id := e.get_instance_id()
		if _born.has(id):
			_reached.erase(id)
			var t := float(Engine.get_physics_frames() - int(_born[id])) / 60.0
			m_ttk.append(t)
			if not m_ttk_by.has(def):
				m_ttk_by[def] = []
			m_ttk_by[def].append(t)
			_born.erase(id))
	var legion := caster.thralls()
	legion.raised.connect(func(t: DmThrall, _corpse: Dictionary) -> void:
		m_thralls_raised += 1
		t.damaged.connect(func(amount: float, _hp: float, from: Node) -> void:
			m_thrall_hurt += amount
			var by: String = from.def_id if from is DmEnemy else "other"
			_th_last[t.get_instance_id()] = by
			_tally2(m_th_hurt_by, by, amount)))
	legion.thrall_died.connect(func(t: DmThrall, reason: String) -> void:
		m_thralls_lost += 1
		_tally(m_th_lost["reason"], reason)
		_tally(m_th_lost["kind"], String(t.kind))
		_tally(m_th_lost["killer"], String(_th_last.get(t.get_instance_id(), "other"))))
	hero.hurt.connect(func(amount: float, _src: Variant) -> void:
		m_taken += amount
		m_blows += 1
		hero.heal(1.0e9))
	g.hero_died.connect(func(_b: DmHeroBody) -> void: m_hero_deaths += 1)
	caster.event_played.connect(func(ev: Dictionary) -> void:
		if _is_cast(ev):
			var r := String(ev.get("rite", ""))
			m_casts[r] = int(m_casts.get(r, 0)) + 1)


## The Reaper's souls come from the kills the rewards pay her (`DmNextMeta._on_kill_earned`: one soul for every enemy that dies within KILL_REWARD_RANGE of her), and the rewards are
## off in this scenario: the same rule is applied here, on both sides, so her spenders (Reap, Soul Burst, Harvest Spin, Wraith Walk, Unleash Souls) get their souls.
func _bank_soul(x: float, z: float) -> void:
	if hero.family == "reaper" and hero.alive and not hero.p.is_empty() and Vector2(x - hero.position.x, z - hero.position.z).length() < KILL_REWARD_RANGE:
		DmPlayerRules.bag_add(hero.p, 1)


## One cast of a rite: a necromancer's rite plays one `cast` event; each of the Reaper's plays its own (a sweep, a throw, a reap, a walk, a burst, a spin, a release, a harvest, a weave;
## the throw's `tick`s, the release's `hit`s and the rest are follow-ups of the same cast).
static func _is_cast(ev: Dictionary) -> bool:
	var t := String(ev.get("t", ""))
	return t == "cast" or (REAPER_CASTS.has(t) and String(ev.get("rite", "")) in REAPER_RITES)


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
		hero.teleport(Vector3(spawn_x, 0.0, spawn_z))
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
	var legion := caster.thralls()
	var places := legion.places_used()
	m_live_sum += legion.count()
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
		"side": "today", "seed": seed_n, "seconds": seconds, "level": level, "difficulty": difficulty, "area": area, "discipline": discipline, "setup": setup,
		"metrics": {
			"kills": m_kills, "kills_by_kind": m_kills_by, "elite_kills": m_elite_kills,
			"spawned": m_spawned, "spawned_by_kind": m_spawned_by, "elite_spawned": m_elite_spawned, "alive_at_end": _born.size(),
			"hero_damage": m_hero_damage, "thrall_damage": m_thrall_damage, "other_damage": m_other_damage,
			"damage_taken": m_taken, "blows_taken": m_blows, "blows_landed": m_raw_blows, "blow_damage": m_raw_damage, "hero_deaths": m_hero_deaths,
			"thrall_damage_taken": m_thrall_hurt, "thrall_hurt_by_def": m_th_hurt_by, "thralls_lost_by": m_th_lost,
			"ttk": _ttk_stats(m_ttk), "ttk_by_kind": by_kind, "ttk_samples_by_kind": samples, "first_hurt_by_kind": m_reach_by,
			"thralls_raised": m_thralls_raised, "thralls_lost": m_thralls_lost,
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
			printerr("parity scenario: cannot write ", out_path)
	print("PARITY today seed=%d kills=%d spawned=%d hero_dmg=%.0f thrall_dmg=%.0f taken=%.0f ttk_median=%.2f thralls_live=%.2f at_cap=%.2f wall=%.1fs" % [
		seed_n, m_kills, m_spawned, m_hero_damage, m_thrall_damage, m_taken, _ttk_stats(m_ttk)["median"], m_live_sum / maxf(1.0, float(m_samples)), float(m_at_cap) / maxf(1.0, float(m_samples)), wall])
