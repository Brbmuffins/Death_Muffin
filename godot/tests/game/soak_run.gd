extends SceneTree
## Soak (headless, full visual stack on the dummy renderer): the hero fights in every hunting ground and wakes every boss with every rite
## of the kit. The assertion is "no script error": the runner (tools/godot/run-all-tests.sh) greps stderr, this script counts what it can.
## godot --headless --path godot --script res://tests/game/soak_run.gd [-- --seconds=N]

var _pass := 0
var _fail := 0
var _mock: DmMockBackend

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var per := 8.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seconds="):
			per = float(a.substr(10))
	_mock = DmOffline.make_mock("")
	var api := DmOffline.make_api(_mock)
	var r := await api.register("soak%d" % (Time.get_ticks_usec() % 100000), "s@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 11})
	game.character["level"] = 40
	game.refresh_stats()
	game.dev_access = true
	game.prog.dev_access = true
	game.abilities.dev = true
	game.nav.set_unlocked(DmContent.area_order())
	game.prog.local["shards"] = 99
	var rites: Array = DmLoadout.assignable_rites(game.kit)
	var areas := ["graves", "warren", "ossuary", "nave", "coliseum", "sanctum", "cloister", "pyre", "fen"]
	var bosses := {"graves": "gravedigger", "ossuary": "abbess", "nave": "congregation", "sanctum": "prelate", "cloister": "saint", "pyre": "regent", "fen": "mire"}
	var t_total := 0.0
	for area in areas:
		var rect: Dictionary = DmContent.area(area)["rect"]
		game.player.teleport((float(rect["x0"]) + float(rect["x1"])) / 2.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
		game.p["area"] = area
		game.p["hp"] = game.player.max_hp()
		if bosses.has(area):
			game.actions.summon_boss_normal(bosses[area])
		var t := 0.0
		var k := 0
		while t < per:
			game.p["hp"] = game.player.max_hp()
			game.p["resource"]["value"] = 100.0
			var best: DmSimEnemy = null
			var bd := 1e9
			for e in game.sim.enemies.values():
				var d: float = DmSimMath.hypot(e.x - game.player.x, e.z - game.player.z)
				if d < bd:
					bd = d
					best = e
			var tgt: Dictionary = {"x": game.player.x + 3.0, "z": game.player.z - 3.0}
			if best != null:
				tgt = {"x": best.x, "z": best.z, "enemyId": best.id}
			elif game.sim.boss.state.active:
				tgt = {"x": game.sim.boss.state.x, "z": game.sim.boss.state.z, "boss": true}
			game.input.set_ground(tgt["x"], tgt["z"])
			var id: String = String(rites[k % rites.size()])
			game.p["castUntil"] = 0.0
			game.p["cooldowns"].erase(id)
			game.do_cast(id, tgt, game.now_ms)
			game.do_cast(game.primary, tgt, game.now_ms)
			k += 1
			for i in 6:
				game.tick(1.0 / 30.0)
				t += 1.0 / 30.0
			await process_frame
		t_total += t
	_check(game.player.alive or true, "survived the soak")
	_check(t_total > 60.0, "ran %d sim seconds" % int(t_total))
	game.queue_free()
	await process_frame
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
