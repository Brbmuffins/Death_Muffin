extends SceneTree
## Wave spawn distance (owner 2026-10-07: waves climb in outside aggro range so the player sees them coming).
## Every enemy of a fresh wave must stand beyond the core's aggro range of the hero it was spawned around, measured before it can move.
## godot --headless --fixed-fps 60 --path client --script res://tests/spawn_aggro/run.gd

const AREAS := ["graves", "ossuary", "nave", "sanctum", "cloister", "pyre", "warren", "coliseum", "fen"]
const WAVES_PER_AREA := 12
const AGGRO_RANGE := 15.0   ## every body's notice distance in the combat core (tests/core_enemies.gd: "every body's defaults are 15 and 30")

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
	check(DmWaveDirector.SPAWN_MIN > AGGRO_RANGE + 2.2, "spawn ring starts beyond aggro plus a group's fan-out")
	var core: DmCore = g.core_host.core
	for area_id in AREAS:
		d.configure_area(area_id)
		var at := center(area_id)
		g.local_body().teleport(at)
		await ticks(3)
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
				nearest = minf(nearest, Vector2(ep.x - at.x, ep.z - at.z).length())
			for id in core.enemy_ids():
				g.core_host.remove_enemy(int(id))
			await ticks(1)
		check(count > 0, "%s: waves spawned (%d enemies)" % [area_id, count])
		check(nearest > AGGRO_RANGE, "%s: nearest fresh enemy %.1f m, beyond aggro %.0f m" % [area_id, nearest, AGGRO_RANGE])
		print("%s: %d enemies over %d waves, nearest %.1f m" % [area_id, count, WAVES_PER_AREA, nearest])
	print("%d passed, %d failed" % [passed, failed])
	print("%s spawn_aggro %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)
