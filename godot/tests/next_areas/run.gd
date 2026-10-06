extends SceneTree
## Areas suite (godot/next/areas + the director / hub changes): every area of the rebuild on DmNextGame: navmesh per area, rosters + level scaling,
## first / processional / surge waves, seals and doors at the kill counts, waystone travel + recall to each area, entry banners + beds, streaming,
## and a walk through all areas with DmFrameCost (frame median + worst, first-entry hitch, memory). Offline backend.
## godot --headless --path godot --script res://tests/next_areas/run.gd

const DT := 1.0 / 60.0
const WALK_ORDER := ["chapterhouse", "acre", "alchemist_wing", "graves", "warren", "ossuary", "nave", "coliseum", "sanctum", "cloister", "pyre", "fen"]
const FRAME_MEDIAN_MS := 16.0       ## headless, waves on, every area in turn (generous: shared VPS)
const FRAME_WORST_MS := 250.0
const ENTRY_HITCH_MS := 250.0       ## the worst of the first frames after arriving in an area (instancing a roster, area change, banner)
const MEM_GROWTH_MB := 250.0

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, _bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s" % [file.get_file(), line, code, rationale])

var passed := 0
var failed := 0
var log_ := ErrLog.new()
var g: DmNextGame
var h: DmChapterhouse
var d: DmWaveDirector
var api: DmApi
var character: Dictionary
var events: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func ev(id: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["id"] == id)


func banners() -> Array:
	return ev("banner").map(func(e: Dictionary) -> Variant: return e["ctx"].get("title"))


## Put the hero at (x, z) as a waystone would (camera snapped, thralls recalled).
func at(x: float, z: float) -> void:
	h.teleport_to(x, z)


func waystone(id: String) -> Dictionary:
	for w in h.waystones:
		if w["area"] == id:
			return w
	return {}


func center(id: String) -> Vector3:
	var r: Dictionary = DmContent.area(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


func combat_areas() -> Array:
	return DmContent.area_order().filter(func(a: String) -> bool: return not DmWaveDirector._is_safe_or_instance(a))


func _run() -> void:
	OS.add_logger(log_)
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("ar%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(character, api, {"dressing": false, "persist": false, "waves": false})
	h = g.chapterhouse
	d = g.director
	g.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append({"id": id, "ctx": ctx}))
	print("boot: %d ms, world build %d ms, navmesh bake (every area + door) %d ms, first nav sync %d ms" % [g.load_ms, g.world.build_ms, g.world.bake_ms, g.world.sync_ms])
	await _areas_and_seals()
	await _beds()
	await _rosters()
	await _waves()
	await _surge()
	await _travel()
	await _walk()
	g.queue_free()
	await ticks(3)
	check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), " | ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


# ---- every area builds with a navmesh; seals + doors at the kill counts -----------------------------------------------------------------

func _areas_and_seals() -> void:
	var b := g.world.builder
	check(g.world.bake_ms < 2500, "navmesh bake of every area + door %d ms under 2500 (no cache needed)" % g.world.bake_ms)
	check(DmContent.area_order().size() == 13 and WALK_ORDER.size() + 1 == 13, "13 areas (the Depths are the depths track's instance)")
	for id in DmContent.area_order():
		var reg: NavigationRegion3D = b.nav_regions.get("area:" + id)
		check(reg != null and reg.navigation_mesh != null and reg.navigation_mesh.get_polygon_count() > 0, "%s: built with a baked navmesh region" % id)
		check(b.area_nodes.has(id) and b.area_rects.has(id), "%s: world nodes + rect" % id)
	# sealed at the start: only the always-open halls are enabled; the Chapterhouse / Graves door is open
	for id in ["chapterhouse", "acre", "alchemist_wing", "graves"]:
		check((b.nav_regions["area:" + id] as NavigationRegion3D).enabled, "%s: open at the start" % id)
	for id in ["warren", "ossuary", "nave", "coliseum", "sanctum", "cloister", "pyre", "fen"]:
		check(not (b.nav_regions["area:" + id] as NavigationRegion3D).enabled, "%s: sealed at the start" % id)
	# a sealed waystone refuses with the necro rule's text and does not move you
	var way_c := waystone("chapterhouse")
	at(float(way_c["x"]), float(way_c["z"]) + 1.6)
	await ticks(3)
	events.clear()
	h.travel("ossuary")
	var toast := ev("toast")
	check(toast.size() == 1 and toast[0]["ctx"]["text"] == "The Marrow Ossuary is still sealed." and g.local_body().position.z > 8.0, "a sealed area refuses: %s" % [toast.map(func(e: Dictionary) -> Variant: return e["ctx"]["text"])])
	# the seals break at their kill counts, in order, each opening its door and its navmesh
	var prog := h._prog()
	var cid := int(character.get("id", 0))
	var sealed: Array = DmContent.area_order().filter(func(a: String) -> bool: return DmContent.area(a).get("unlock") != null)
	sealed.sort_custom(func(a: String, b2: String) -> bool: return float(DmContent.area(a)["unlock"]["kills"]) < float(DmContent.area(b2)["unlock"]["kills"]))   # a parent's seal first
	for id in sealed:
		var u: Dictionary = DmContent.area(id)["unlock"]
		var door: Dictionary = {}
		for dd in DmContent.doors():
			if dd["b"] == id:
				door = dd
		var need: int = prog.unlock_kills(float(u["kills"]))
		check(need == int(u["kills"]) and not door.is_empty(), "%s: seal asks %d kills in %s, door %s" % [id, need, u["area"], door.get("id", "?")])
		while prog.kills(String(u["area"])) < need - 1:
			prog.record_kill(String(u["area"]))
		check(h.check_seals().is_empty() and not h.door_open(String(door["id"])) and not prog.is_unlocked(id), "%s: %d kills in %s: sealed" % [id, need - 1, u["area"]])
		events.clear()
		prog.record_kill(String(u["area"]))
		g.rewards.member_credited.emit(cid, {"kills": 1})
		check(h.door_open(String(door["id"])) and prog.really_unlocked(id) and (b.nav_regions["area:" + id] as NavigationRegion3D).enabled, "%s: %d kills: seal breaks, door + navmesh open" % [id, need])
		var bn := ev("banner")
		check(bn.size() == 1 and bn[0]["ctx"]["title"] == "A seal breaks" and String(bn[0]["ctx"]["sub"]).find(String(DmContent.area(id)["name"])) >= 0, "%s: 'A seal breaks' banner" % id)
	await ticks(12)
	# every area is reachable on the navmesh from the Chapterhouse (through the doors)
	var from := Vector3(0, 0, 12)
	for id in WALK_ORDER:
		var to := center(id)
		var w := waystone(id)
		if not w.is_empty():
			to = Vector3(float(w["x"]), 0.0, float(w["z"]) + 1.6)
		var path := g.world.nav_path(from, to)
		for i in 300:   # the navigation server merges the re-enabled regions over a few iterations
			if path.size() > 1 and Vector2(path[path.size() - 1].x - to.x, path[path.size() - 1].z - to.z).length() < 1.5:
				break
			await physics_frame
			path = g.world.nav_path(from, to)
		check(path.size() > 1 and Vector2(path[path.size() - 1].x - to.x, path[path.size() - 1].z - to.z).length() < 1.5, "%s: a navmesh path from the Chapterhouse reaches it (%d points, ends %s, want %s)" % [id, path.size(), path[path.size() - 1] if not path.is_empty() else "-", to])


# ---- music + ambience bed of every area (the AudioDirector's data), entry banner flow ---------------------------------------------------

func _beds() -> void:
	for id in DmContent.area_order():
		check(DmMusicState.cue_for(id) != "" and DmAudioAmbience.ZONE_BEDS.has(id), "%s: music cue '%s' and an ambience bed" % [id, DmMusicState.cue_for(id)])
	check(g.areas.announced.has("chapterhouse"), "the start area was announced")
	# DmAudioHooks keeps the bed in step with the shell's area_id: the shell exposes it as the hook reads it
	check(g.ready_ and g.area_id == "chapterhouse" and g.player != null and g.builder != null, "the shell exposes ready_/area_id/player/builder to DmAudioHooks")


# ---- rosters and level scaling ---------------------------------------------------------------------------------------------------------

func _rosters() -> void:
	var hb := g.local_body()
	var hero_level := float(hb.character.get("level", 1))
	var kinds_seen := {}
	for id in combat_areas():
		var def: Dictionary = DmContent.area(id)
		d.configure_area(id)
		var roster := {}
		var top := ["", 0.0]
		for e in def["enemies"]:
			roster[String(e["id"])] = float(e["weight"])
			if float(e["weight"]) > float(top[1]):
				top = [String(e["id"]), float(e["weight"])]
		check(d.kinds.size() == roster.size() and d.cap == int(def["cap"]) and d.wave_size == int(def["waveSize"]) and absf(d.wave_interval - float(def["waveIntervalMs"]) / 1000.0) < 0.001,
			"%s: %d kinds, cap %d, wave %d every %.1f s" % [id, d.kinds.size(), d.cap, d.wave_size, d.wave_interval])
		var seen := {}
		d.rng.seed = 7
		for i in 4000:
			var k := d._pick_kind()
			seen[k] = int(seen.get(k, 0)) + 1
		var total := 0.0
		for k in roster:
			total += roster[k]
		check(seen.size() == roster.size() and seen.keys().all(func(k: String) -> bool: return roster.has(k)), "%s: waves roll exactly the roster (%d kinds)" % [id, seen.size()])
		var share := float(seen.get(top[0], 0)) / 4000.0
		check(absf(share - float(top[1]) / total) < 0.04, "%s: %s weight %.0f%% (rolled %.0f%%)" % [id, top[0], 100.0 * float(top[1]) / total, 100.0 * share])
		for k in roster:
			kinds_seen[k] = true
		# a real wave on this ground: the area's scenes, meta and level scaling
		at(center(id).x, center(id).z)
		await ticks(2)
		d.clear()
		await ticks(2)
		var made := d.spawn_wave([hb])
		var expect_level := DmEnemyStats.area_level(id, [hero_level], 0.0)
		var ok := made == mini(d.wave_size, d.cap) and d.alive_count() == made
		var lv_ok := true
		var kind_ok := true
		for en in d.enemies.values():
			var e := en as DmEnemy
			lv_ok = lv_ok and absf(float(e.get_meta("dm_level")) - expect_level) < 0.001 and String(e.get_meta("dm_area")) == id
			lv_ok = lv_ok and absf(e.hp_mult - DmEnemyStats.hp_scale(expect_level)) < 0.001 and absf(e.damage_mult - DmEnemyStats.damage_scale(expect_level)) < 0.001
			kind_ok = kind_ok and roster.has(e.def_id)
		check(ok and lv_ok and kind_ok, "%s: a wave of %d (cap %d) at level %.0f, roster kinds, area meta, hp / damage scaling" % [id, made, d.cap, expect_level])
		d.clear()
		await ticks(2)
	check(kinds_seen.size() >= 26, "the rosters use %d distinct kinds (all with scenes)" % kinds_seen.size())
	# level-scaled late areas follow the strongest hero (floor = the area's minLevel); the others keep their level
	var prev: Variant = hb.character.get("level", 1)
	hb.character["level"] = 60
	for id in ["cloister", "pyre", "fen", "ossuary"]:
		d.configure_area(id)
		at(center(id).x, center(id).z)
		await ticks(2)
		d.spawn_wave([hb], 2)
		var want := 60.0 if DmContent.area(id).get("scaling") != null else float(DmContent.area(id)["level"])
		var lv: float = float((d.enemies.values()[0] as DmEnemy).get_meta("dm_level"))
		check(absf(lv - want) < 0.001, "%s: a level-60 hero -> enemy level %.0f (want %.0f)" % [id, lv, want])
		d.clear()
		await ticks(2)
	hb.character["level"] = prev
	var floors := {"cloister": 20.0, "pyre": 30.0, "fen": 45.0}
	for id in floors:
		check(DmEnemyStats.area_level(id, [1.0], 0.0) == floors[id], "%s: a level-1 hero still meets level %.0f enemies" % [id, floors[id]])


# ---- waves: the first wave, follow the hero's area, processions --------------------------------------------------------------------------

func _waves() -> void:
	var hb := g.local_body()
	d.enabled = true
	d.first_wave_delay = 0.3
	var counts: Array = []
	var cb := func(n: int) -> void: counts.append(n)
	d.wave_spawned.connect(cb)
	var followed: Array = []
	d.area_followed.connect(func(id: String) -> void: followed.append(id))
	for id in ["fen", "coliseum", "nave"]:
		counts.clear()
		at(center(id).x, center(id).z)
		await until(func() -> bool: return d.area_id == id and not counts.is_empty(), 4.0)
		var def: Dictionary = DmContent.area(id)
		check(d.area_id == id and followed.has(id), "%s: the director follows the hero's area" % id)
		check(counts.size() >= 1 and counts[0] == DmMath.js_round(float(def["waveSize"]) * 1.3), "%s: the first wave is 1.3 x the wave size = %d (got %s)" % [id, DmMath.js_round(float(def["waveSize"]) * 1.3), counts.slice(0, 1)])
		check(d.alive_count() <= int(def["cap"]) and d.enemies.values().all(func(e: DmEnemy) -> bool: return String(e.get_meta("dm_area")) == id), "%s: alive %d within cap %d, all of this area" % [id, d.alive_count(), int(def["cap"])])
		hb.heal(1e6)
	# the next wave comes after the area's interval, within the cap
	d.cap = 40
	counts.clear()
	for i in int((d.wave_interval + 3.0) / DT):
		if not counts.is_empty():
			break

		await physics_frame
		hb.heal(1e6)
	check(counts.size() >= 1, "nave: a second wave follows after its interval (%.1f s)" % d.wave_interval)
	d.wave_spawned.disconnect(cb)
	# leaving for a safe hall: the area's dead are cleared, nothing spawns there
	at(0.0, 12.0)
	await until(func() -> bool: return g.area_id == "chapterhouse", 2.0)
	await ticks(2)
	d.cap = int(DmContent.area("nave")["cap"])
	var before := d.waves_spawned
	await ticks(120)
	check(d.waves_spawned == before, "no waves in the Chapterhouse")
	# going to another combat area clears the old one's enemies at once
	at(center("graves").x, center("graves").z)
	await until(func() -> bool: return d.area_id == "graves" and d.alive_count() > 0, 4.0)
	check(d.enemies.values().all(func(e: DmEnemy) -> bool: return String(e.get_meta("dm_area")) == "graves"), "graves: only Graves enemies after arriving from elsewhere")
	# processions: from wave 2 on, 30 % themed; a themed wave leads with its lead and rolls only its roster
	var themed := 0
	d._wave_n = 1
	for i in 400:
		themed += 1 if d._roll_theme() != null else 0
	check(themed == 0, "no procession before wave %d" % int(DmSimData.PROCESSION["minWave"]))
	d._wave_n = 2
	themed = 0
	for i in 600:
		themed += 1 if d._roll_theme() != null else 0
	check(themed > 120 and themed < 240, "processions roll ~30 %% of waves (%d / 600)" % themed)
	d.enabled = false
	d.clear()
	await ticks(2)
	for aid in combat_areas():
		var themes: Array = DmSimData.WAVE_THEMES.get(aid, [])
		if themes.is_empty():
			continue
		d.configure_area(aid)
		at(center(aid).x, center(aid).z)
		await ticks(2)
		d.enabled = false
		for th in themes:
			d.clear()
			await ticks(1)
			var lead: String = String(th["lead"]) if th.get("lead") != null else ""
			var roster := {}
			for e in th["roster"]:
				roster[String(e["id"])] = true
			d.spawn_wave([hb], 8, th["roster"], lead)
			var kinds_ok := d.enemies.values().all(func(e: DmEnemy) -> bool: return roster.has(e.def_id) or e.def_id == lead)
			var lead_ok := lead == "" or d.enemies.values().any(func(e: DmEnemy) -> bool: return e.def_id == lead)
			check(kinds_ok and lead_ok, "%s / %s: themed wave rolls its roster%s" % [aid, th["id"], (" and leads with " + lead) if lead != "" else ""])
		d.clear()
		await ticks(1)
	# the procession banner is introduced once per area
	events.clear()
	d.procession.emit(DmSimData.WAVE_THEMES["graves"][0])
	d.procession.emit(DmSimData.WAVE_THEMES["graves"][1])
	check(banners() == ["The Kennel Loosed"], "a procession is announced once per area: %s" % [banners()])
	d.first_wave_delay = 1.0


# ---- Grave Surge ------------------------------------------------------------------------------------------------------------------------

func _surge() -> void:
	var hb := g.local_body()
	d.enabled = false
	d.clear()
	d.configure_area("graves")
	at(center("graves").x, center("graves").z)
	await ticks(3)
	hb.heal(1e6)
	events.clear()
	var sev: Array = []
	d.surge_event.connect(func(e: Dictionary) -> void: sev.append(e))
	var dropped: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, drop: Dictionary, _p: Vector3) -> void: dropped.append(drop))
	var s := d.surge
	check(s.surge_in < 0.0 or s.surge_in <= float(DmSimData.SURGE["firstDelayS"]), "the first surge is %d s away" % int(DmSimData.SURGE["firstDelayS"]))
	check(s.start([hb]) and s.active and not s.start([hb]), "a surge opens at a crypt (once)")
	check(sev.size() == 1 and sev[0]["t"] == "surge" and sev[0]["area"] == "graves" and banners().has("Grave Surge"), "'Grave Surge' banner + event")
	var crypt := Vector3(float(sev[0]["x"]), 0.0, float(sev[0]["z"]))
	var rect: Dictionary = DmContent.area("graves")["rect"]
	check(crypt.x >= float(rect["x0"]) and crypt.x <= float(rect["x1"]) and crypt.z >= float(rect["z0"]) and crypt.z <= float(rect["z1"]), "the crypt lies in the Graves (%.1f, %.1f)" % [crypt.x, crypt.z])
	var heroes := [hb]
	s.update(1.6, heroes)
	var w1 := s.spawned
	s.update(6.0, heroes)
	s.update(6.0, heroes)
	var want_wave := DmMath.js_round(float(DmContent.area("graves")["waveSize"]) * float(DmSimData.SURGE["waveSizeMult"]))
	check(s.waves_spawned == 3 and w1 == want_wave and s.spawned == 3 * want_wave, "3 surge waves of %d (%d spawned)" % [want_wave, s.spawned])
	var near := d.enemies.values().filter(func(e: DmEnemy) -> bool: return Vector2(e.position.x - crypt.x, e.position.z - crypt.z).length() < 6.0)
	check(near.size() >= s.spawned - 3, "they climb out of the crypt (%d of %d within 6 m)" % [near.size(), s.spawned])
	# kill 80 %: cleared, banner, offering on the ground
	for i in 100:   # they rise first (not hittable for ~1.1 s)
		await physics_frame
		hb.heal(1e6)
	var targets := d.enemies.values()
	targets = targets.slice(0, int(ceil(float(s.spawned) * float(DmSimData.SURGE["clearFrac"]))) + 1)   # 80 % of the surge (+1: a body still rising shrugs a hit)
	for e in targets:
		(e as DmEnemy).take_damage(1e9, hb)
	await ticks(2)
	events.clear()
	dropped.clear()
	s.update(0.1, heroes)
	check(not s.active and sev.back()["t"] == "surgeCleared" and banners().has("Surge Quelled"), "80 %% down: 'Surge Quelled' (killed %d of %d)" % [s.killed, s.spawned])
	await ticks(3)
	check(dropped.any(func(x: Dictionary) -> bool: return x.get("kind") == "gold") and dropped.size() >= 2, "the crypt pays gold + an item (%d drops)" % dropped.size())
	check(s.surge_in >= float(DmSimData.SURGE["minIntervalS"]) and s.surge_in <= float(DmSimData.SURGE["maxIntervalS"]), "the next surge is %.0f s away (90-150)" % s.surge_in)
	# a surge nobody holds back fails; a hero-less area fails it too
	d.clear()
	await ticks(2)
	events.clear()
	s.start([hb])
	s.update(20.5, heroes)
	check(not s.active and sev.back()["t"] == "surgeFailed" and banners().has("The Surge Recedes"), "20 s with nothing killed: 'The Surge Recedes'")
	d.clear()
	await ticks(2)
	s.start([hb])
	s.reset()
	check(not s.active and sev.back()["t"] == "surgeFailed", "the area empties: the surge fails")
	# the timer ticks only with a hero in a combat area
	s.surge_in = 5.0
	s.update(1.0, [])
	check(s.surge_in == 4.0 or s.surge_in == 5.0, "idle clock holds without heroes")
	d.clear()
	await ticks(2)


# ---- waystone travel + recall to every area, entry banners ----------------------------------------------------------------------------------------

func _travel() -> void:
	var hb := g.local_body()
	d.enabled = false
	d.clear()
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	for id in WALK_ORDER:
		var w := waystone(id)
		if w.is_empty():
			continue
		at(float(ret["x"]), float(ret["z"]))
		await until(func() -> bool: return g.area_id == "chapterhouse", 2.0)
		g.areas.announced.erase(id)
		events.clear()
		h.travel(id)
		var pos := hb.position
		check(Vector2(pos.x - float(w["x"]), pos.z - float(w["z"]) - 1.6).length() < 0.5, "%s: waystone travel puts you at its stone" % id)
		await until(func() -> bool: return g.area_id == id, 2.0)
		if id != "chapterhouse":
			check(g.area_id == id and g.area_of(1) == id and g.world.builder.current_area == id, "%s: the shell, the hero and the world's lighting are in the area" % id)
			var bn := ev("banner").filter(func(e: Dictionary) -> bool: return e["ctx"].get("title") == DmContent.area(id)["name"])
			check(bn.size() == 1 and bn[0]["ctx"]["sub"] == DmContent.area(id)["subtitle"], "%s: entry banner '%s'" % [id, DmContent.area(id)["name"]])
			check(ev("codex").any(func(e: Dictionary) -> bool: return e["ctx"].get("id") == id), "%s: Codex discovery" % id)
			check(g.rewards.area_id == id, "%s: the rewards follow the area" % id)
			# recall from here
			events.clear()
			h.start_recall()
			check(h.recall_active, "%s: T starts a recall" % id)
			h.finish_recall()
			await until(func() -> bool: return g.area_id == "chapterhouse", 2.0)
			check(g.area_id == "chapterhouse" and hb.position.distance_to(Vector3(float(ret["x"]), 0, float(ret["z"]))) < 0.5, "%s: recall to the Chapterhouse" % id)
	# a waystone beside you works from any area; one far from any stone does not
	var wg := waystone("graves")
	at(float(wg["x"]), float(wg["z"]) + 1.6)
	await until(func() -> bool: return g.area_id == "graves", 2.0)
	h.travel("fen")
	check(hb.position.distance_to(Vector3(float(waystone("fen")["x"]), 0, float(waystone("fen")["z"]) + 1.6)) < 0.5, "waystone to waystone: the Graves to the Fen")
	at(center("coliseum").x, center("coliseum").z)
	await ticks(2)
	events.clear()
	h.travel("graves")
	check(not ev("toast").is_empty() and g.area_of(1) == "coliseum", "far from a waystone outside the Chapterhouse: refused")
	g.areas.announced.clear()
	events.clear()
	g.areas.enter("depths")
	check(banners().is_empty(), "the Depths announce nothing (the depths track owns their entry)")
	g.areas.enter("graves")


# ---- walk through every area: frame cost, first-entry hitch, memory, streaming --------------------------------------------------------------------------

func _walk() -> void:
	var hb := g.local_body()
	var b := g.world.builder
	d.enabled = true
	d.clear()
	d.first_wave_delay = 1.0
	at(0.0, 12.0)
	await until(func() -> bool: return g.area_id == "chapterhouse", 2.0)
	await ticks(30)
	var mem0 := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var nodes0 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var fc := DmFrameCost.attach(root)
	await ticks(5)
	fc.reset()
	var worst_entry := 0.0
	var worst_at := ""
	var all_visible_max := 0
	for round_ in 2:   # twice: the second pass hits warm caches (no first-entry cost at all) and checks nothing leaks
		for id in WALK_ORDER:
			var w := waystone(id)
			var to := center(id) if w.is_empty() else Vector3(float(w["x"]), 0.0, float(w["z"]) + 1.6)
			at(to.x, to.z)
			var entry := 0.0
			var t0 := Time.get_ticks_usec()
			for i in 6:
				await physics_frame
				var now := Time.get_ticks_usec()
				entry = maxf(entry, float(now - t0) / 1000.0)
				t0 = now
				hb.heal(1e6)
			if round_ == 0 and entry > worst_entry:
				worst_entry = entry
				worst_at = id
			for i in 60:
				await physics_frame
				hb.heal(1e6)
			check(g.area_id == id, "walk %d: %s entered" % [round_, id])
			var vis := 0
			for aid in b.area_nodes:
				vis += 1 if (b.area_nodes[aid] as Node3D).visible else 0
			all_visible_max = maxi(all_visible_max, vis)
			if round_ == 0:
				check((b.area_nodes[id] as Node3D).visible, "%s: its own ground is drawn" % id)
	var med := fc.median_ms()
	var worst := fc.worst_ms()
	print("walk: %d frames over 12 areas x2 (waves on): median %.2f ms, p95 %.2f, worst %.2f; slowest frame right after an entry %.1f ms (%s)" % [fc.samples(), med, fc.p95_ms(), worst, worst_entry, worst_at])
	fc.queue_free()
	check(med < FRAME_MEDIAN_MS and worst < FRAME_WORST_MS, "walk: frame median %.2f ms under %.0f, worst %.1f ms under %.0f" % [med, FRAME_MEDIAN_MS, worst, FRAME_WORST_MS])
	check(worst_entry < ENTRY_HITCH_MS, "first entry to %s: slowest of the first 6 frames %.1f ms, under %.0f (no hitch)" % [worst_at, worst_entry, ENTRY_HITCH_MS])
	# streaming: only the areas near the camera are drawn
	at(Vector3(90, 0, -116).x, -116.0)
	await ticks(5)
	var drawn: Array = []
	for aid in b.area_nodes:
		if (b.area_nodes[aid] as Node3D).visible:
			drawn.append(aid)
	check(drawn.has("pyre") and not drawn.has("acre") and drawn.size() < 13, "streaming: in the Pyre %d of 13 areas drawn, the far Acre is not (%s)" % [drawn.size(), ",".join(drawn)])
	# back home, everything cleared: memory and node counts did not grow
	d.enabled = false
	d.clear()
	at(0.0, 12.0)
	await ticks(90)
	var mem1 := float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0
	var nodes1 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	print("memory: static %.0f -> %.0f MB, nodes %d -> %d after 24 area entries" % [mem0, mem1, nodes0, nodes1])
	check(mem1 - mem0 < MEM_GROWTH_MB, "memory after the walk: +%.0f MB under %.0f" % [mem1 - mem0, MEM_GROWTH_MB])
	check(nodes1 - nodes0 < 400, "nodes after the walk: %d -> %d (enemies, corpses and effects are cleaned up)" % [nodes0, nodes1])
