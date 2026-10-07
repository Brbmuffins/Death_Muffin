extends SceneTree
## Wave spawn distance (owner 2026-10-07: waves climb in outside aggro range so the player sees them coming).
## Every enemy of a fresh wave must stand beyond DmEnemy.AGGRO_RANGE of the hero it was spawned around, measured before it can move.
## godot --headless --path godot --script res://tests/next_spawn_aggro/run.gd

const AREAS := ["graves", "ossuary", "nave", "sanctum", "cloister", "pyre", "warren", "coliseum", "fen"]
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
	await g.start(c.data, api, {"dressing": false, "persist": false})
	d = g.director
	d.warm(false)
	await ticks(10)
	check(DmWaveDirector.SPAWN_MIN > DmEnemy.AGGRO_RANGE + 2.2, "spawn ring starts beyond aggro plus a group's fan-out")
	for area_id in AREAS:
		d.configure_area(area_id)
		var at := center(area_id)
		g.player.position = at
		await ticks(3)
		var nearest := INF
		var count := 0
		for w in WAVES_PER_AREA:
			var before := {}
			for id in d.enemies:
				before[id] = true
			d.spawn_wave([g.player], 4)
			for id in d.enemies:
				if before.has(id):
					continue
				var e: Node3D = d.enemies[id]
				if e == null or not is_instance_valid(e):
					continue
				count += 1
				nearest = minf(nearest, Vector2(e.position.x - at.x, e.position.z - at.z).length())
			d.clear()
			await ticks(1)
		check(count > 0, "%s: waves spawned (%d enemies)" % [area_id, count])
		check(nearest > DmEnemy.AGGRO_RANGE, "%s: nearest fresh enemy %.1f m, beyond aggro %.0f m" % [area_id, nearest, DmEnemy.AGGRO_RANGE])
		print("%s: %d enemies over %d waves, nearest %.1f m" % [area_id, count, WAVES_PER_AREA, nearest])
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
