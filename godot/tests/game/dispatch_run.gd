extends SceneTree
## Regression: inside a visual DmGame each host answer reaches the ability system once. DmAbilitySystem.handle_event and the event
## router (DmEventFx, the port of WorldScene) both used to route rally / seeded / mantle / offering / litanyResult / detonated, so every
## effect was drawn twice and Litany / Mantle barriers were paid twice. Compares the ability fx counters after DmGame.handle_event with
## one direct call of the same handler.
## godot --headless --path godot --script res://tests/game/dispatch_run.gd

var _pass := 0
var _fail := 0

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _initialize() -> void:
	_run.call_deferred()

func _total(ab: Object) -> int:
	var n := 0
	for k in ab.stats:
		n += int(ab.stats[k])
	return n

func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("disp%d" % (Time.get_ticks_usec() % 100000), "d@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 3, "warmup": false})
	_check(game.event_fx != null, "visual game has the event router")
	var me: String = game.self_id
	var x: float = game.player.x
	var z: float = game.player.z - 3.0
	var ab: Object = game.abilities
	var cases := [
		[{"t": "litanyResult", "by": me, "x": x, "z": z, "r": 5.0, "corpses": 1, "resonant": 0, "thralls": 0, "spared": 0, "tethers": [[x + 1.0, z]]},
			func(ev): ab.on_litany(ev, true)],
		[{"t": "mantle", "by": me, "x": x, "z": z, "corpses": 1, "tethers": [[x + 1.0, z]]},
			func(ev): ab.on_mantle(ev, true)],
		[{"t": "offering", "by": me, "ok": true, "x": x, "z": z, "corpseId": 991},
			func(ev): ab.on_offering(ev, true)],
		[{"t": "detonated", "by": me, "ok": true, "x": x, "z": z, "corpseId": 992, "kind": "normal", "r": 2.5, "dmg": 10.0, "targets": 1, "elite": false},
			func(ev): ab.on_detonated(ev, true)],
		[{"t": "rally", "by": me, "x": x, "z": z, "ids": []},
			func(ev): ab.on_rally(ev)],
		[{"t": "seeded", "by": me, "x": x, "z": z, "corpseId": 993, "armMs": 600.0},
			func(ev): ab.on_seeded(ev)],
	]
	for cs in cases:
		var ev: Dictionary = cs[0]
		var t0 := _total(ab)
		(cs[1] as Callable).call(ev.duplicate(true))
		var once := _total(ab) - t0
		var t1 := _total(ab)
		game.handle_event(ev.duplicate(true))
		var routed := _total(ab) - t1
		_check(once > 0, "%s: the handler draws something (%d)" % [ev["t"], once])
		_check(routed == once, "%s: routed through DmGame once (%d fx, one call = %d)" % [ev["t"], routed, once])
	print("%d passed, %d failed" % [_pass, _fail])
	game.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _fail > 0 else 0)
