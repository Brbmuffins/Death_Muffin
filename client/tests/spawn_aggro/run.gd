extends SceneTree
## Wave spawn distance (owner 2026-10-07: waves climb in outside aggro range so the player sees them coming).
## Every enemy of a fresh wave must stand beyond the core's aggro range of the hero it was spawned around, measured before it can move. In a party apart that is the member
## standing in another area, not the host: the waves of an area a member fights in climb in around that member, in every combat area.
## godot --headless --fixed-fps 60 --path client --script res://tests/spawn_aggro/run.gd

const WAVES_PER_AREA := 12

var passed := 0
var failed := 0
var g: DmNextGame
var d: DmWaveDirector


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


## The areas that run waves: the world's areas (the Depths are an instance with its own tests) that have a roster to spawn.
func combat_areas() -> Array[String]:
	var out: Array[String] = []
	for id in DmNextWorld.every_area():
		if not bool(DmContent.area(id).get("safe", false)) and not (DmContent.area(id).get("enemies", []) as Array).is_empty():
			out.append(id)
	return out


func center(id: String) -> Vector3:
	var r: Dictionary = DmContent.area(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("sp" + str(Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	OS.set_environment("DM_SYNC_NAV", "1")   # a region enabled by set_unlocked is merged in step with game time (the run is --fixed-fps)
	await g.start(c.data, api, {"dressing": false, "persist": false, "hud": true})
	d = g.director
	g.world.set_unlocked(DmNextWorld.every_area(), true)   # the client's navmesh of an area is on only while the area is unlocked: the spawn ring needs it
	await ticks(10)
	check(DmWaveDirector.SPAWN_MIN > DmSimConsts.AGGRO_RANGE + 2.2, "spawn ring starts beyond aggro plus a group's fan-out")
	var core: DmCore = g.core_host.core
	var areas := combat_areas()
	check(not areas.is_empty(), "the world has areas that run waves (%s)" % ", ".join(areas))
	for area_id in areas:
		d.configure_area(area_id)
		var at := center(area_id)
		g.local_body().teleport(at)
		await ticks(3)
		var margin := INF   ## the least a fresh enemy stands beyond ITS OWN notice distance (the combat core's `aggro` of the body)
		var nearest := INF
		var count := 0
		for w in WAVES_PER_AREA:
			var before := {}
			for id in core.enemy_ids():
				before[int(id)] = true
			d.spawn_wave([g.local_body()], 4)
			d.flush_spawns()
			for id in core.enemy_ids():
				if before.has(int(id)):
					continue
				count += 1
				var ep: Vector3 = g.core_host.enemy_position(int(id))
				var far := Vector2(ep.x - at.x, ep.z - at.z).length()
				nearest = minf(nearest, far)
				margin = minf(margin, far - float(core.enemy_info(int(id))["aggro"]))
			for id in core.enemy_ids():
				g.core_host.remove_enemy(int(id))
			await ticks(1)
		check(count > 0, "%s: waves spawned (%d enemies)" % [area_id, count])
		check(margin > 0.0, "%s: nearest fresh enemy %.1f m, %.1f m beyond its own notice distance" % [area_id, nearest, margin])
		print("%s: %d enemies over %d waves, nearest %.1f m" % [area_id, count, WAVES_PER_AREA, nearest])
	await party_apart(areas)
	print("%d passed, %d failed" % [passed, failed])
	print("%s spawn_aggro %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


## The host stays in the Graves and a second player stands in each other combat area in turn: the director's own waves for that area climb in around the player standing there.
func party_apart(areas: Array[String]) -> void:
	var home := "graves"
	var core: DmCore = g.core_host.core
	for id in core.enemy_ids():
		g.core_host.remove_enemy(int(id))
	d.configure_area(home)
	g.local_body().teleport(g.world.nav_closest(center(home)))
	g.session._accept(7, "mate", "gravecaller")   # a second player: its body in the host's session, as a joiner's (the director reads where the party stands)
	var mate: DmHeroBody = g.body_of(7)
	var seen := {"area": "", "margin": INF, "nearest": INF, "ids": []}
	g.core_host.enemy_spawned.connect(func(id: int, _def: String, _level: int, _elite: bool, area: String, _af: int, x: float, z: float, _hp: float) -> void:
		if area != String(seen["area"]):
			return
		(seen["ids"] as Array).append(id)
		var far := Vector2(x - mate.position.x, z - mate.position.z).length()
		seen["nearest"] = minf(float(seen["nearest"]), far)
		seen["margin"] = minf(float(seen["margin"]), far - float(core.enemy_info(id)["aggro"])))
	d.enabled = true
	for area_id in areas:
		if area_id == home:
			continue
		seen["area"] = area_id
		seen["margin"] = INF
		seen["nearest"] = INF
		seen["ids"] = []
		mate.teleport(g.world.nav_closest(center(area_id)))
		var end := Engine.get_physics_frames() + 60 * 10
		while (seen["ids"] as Array).size() < 4 and Engine.get_physics_frames() < end:
			await physics_frame
		check(not (seen["ids"] as Array).is_empty(), "%s: the director sends waves to a member standing there while the host is in the Graves (%d enemies)" % [area_id, (seen["ids"] as Array).size()])
		check(float(seen["margin"]) > 0.0, "%s: the nearest fresh enemy is %.1f m from the member, %.1f m beyond its own notice distance" % [area_id, float(seen["nearest"]), float(seen["margin"])])
		for id in seen["ids"]:
			g.core_host.remove_enemy(int(id))
		await ticks(1)
	d.enabled = false
	g.session._remove_player(7)
	for id in core.enemy_ids():
		g.core_host.remove_enemy(int(id))
	await ticks(2)
