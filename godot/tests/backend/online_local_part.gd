extends "res://tests/common/dm_suite_part.gd"
## Online-path regressions that need no live server (the live end-to-end check is tests/online_live, opt-in):
##  1. DmProgressSync.spend_on_server must not lose gold picked up while its pre-save is in flight,
##  2. a failed pre-save must not let the spend go through on stale server gold,
##  3. a backend without /api/sessions (live server, migration 041 not applied): DmSessionRewards falls back to the kill ledger
##     (/api/kills/report) so XP and kill counts are still credited, on the very first flush and again at end_session.
## godot --headless --path godot --script res://tests/backend/run.gd

var _p := 0
var _f := 0
var _clock := [1_790_000_000_000]


class Shell extends Node:
	signal enemy_spawned(enemy)


func ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		_p += 1
	else:
		_f += 1
		print("FAIL: ", label, " ", extra)


func _initialize() -> void:
	await _main()


## A transport that holds /save-progress for `hold_frames` (a pickup lands meanwhile) and can fail it.
class SlowWire extends RefCounted:
	var hold_frames := 0
	var fail_save := false
	var during: Callable = Callable()
	var saved_gold := -1
	func call_it(req: Dictionary) -> Dictionary:
		if String(req["url"]).ends_with("/save-progress"):
			var tree := Engine.get_main_loop() as SceneTree
			for i in hold_frames:
				if i == 1 and during.is_valid():
					during.call()
				await tree.process_frame
			if fail_save:
				return {"status": 500, "text": "{}"}
			saved_gold = int(JSON.parse_string(String(req["body"])).get("gold", -1))
			return {"status": 200, "text": JSON.stringify({"success": true, "data": {}})}
		return {"status": 404, "text": ""}


## Offline backend, but POST /api/sessions answers like a server without the route (HTML 404, no JSON error).
class NoSessions extends RefCounted:
	var inner: Callable
	var ledger_posts := 0
	func call_it(req: Dictionary) -> Dictionary:
		var url := String(req["url"])
		if url.ends_with("/api/sessions") and String(req["method"]) == "POST":
			return {"status": 404, "text": "<html>Cannot POST</html>"}
		if url.ends_with("/api/kills/report"):
			ledger_posts += 1
		return await inner.call(req)


func _spend_race() -> void:
	var wire := SlowWire.new()
	var api := DmApi.new(Callable(wire, "call_it"))
	api.set_token("t")
	var prog := DmProgression.new({"level": 1, "experience": 0, "gold": 100}, null)
	var ps := DmProgressSync.new(api, prog, 1, false)
	wire.hold_frames = 4
	wire.during = func() -> void: prog.add_gold(50.0)   # a pickup while the pre-save is in flight
	var r: DmResult = await ps.spend_on_server(func() -> DmResult:
		return DmResult.success({"gold": 70, "cost": 30}, 200))   # the server priced from the 100 it was sent
	ok(r.ok and wire.saved_gold == 100, "pre-save carried the gold at the time of the spend", str(wire.saved_gold))
	ok(int(prog.character["gold"]) == 120, "gold picked up during the pre-save survives the spend (100 - 30 + 50)", str(prog.character["gold"]))
	# a pickup during the spend call itself
	wire.during = Callable()
	r = await ps.spend_on_server(func() -> DmResult:
		prog.add_gold(5.0)
		return DmResult.success({"gold": 90, "cost": 30}, 200))
	ok(int(prog.character["gold"]) == 95, "gold picked up during the spend call survives too", str(prog.character["gold"]))
	# a failed pre-save: the spend is refused, nothing is taken, gold stays
	wire.fail_save = true
	var called := [false]
	r = await ps.spend_on_server(func() -> DmResult:
		called[0] = true
		return DmResult.success({"gold": 0, "cost": 30}, 200))
	ok(not r.ok and not called[0] and int(prog.character["gold"]) == 95, "failed pre-save refuses the spend", str(r.error))


## roll-gear holds a DB connection per request on the live backend (a burst wedged it): one roll in flight per client.
class RollWire extends RefCounted:
	var inflight := 0
	var peak := 0
	func call_it(_req: Dictionary) -> Dictionary:
		inflight += 1
		peak = maxi(peak, inflight)
		await (Engine.get_main_loop() as SceneTree).process_frame
		await (Engine.get_main_loop() as SceneTree).process_frame
		inflight -= 1
		return {"status": 200, "text": JSON.stringify({"success": true, "data": []})}


func _roll_serialised() -> void:
	var wire := RollWire.new()
	var api := DmApi.new(Callable(wire, "call_it"))
	api.set_token("t")
	var done := [0]
	for i in 12:
		(func() -> void:
			var r := await api.roll_loot(1, [{"item_id": "helm_copper", "level": 3, "source": "kill"}])
			if r.ok:
				done[0] += 1).call()
	while done[0] < 12:
		await process_frame
	ok(wire.peak == 1, "twelve concurrent roll_loot calls reach the server one at a time (peak %d)" % wire.peak)


func _ledger_fallback() -> void:
	var mock := DmOffline.make_mock("")
	mock.now_ms = func(): return _clock[0]
	var wire := NoSessions.new()
	wire.inner = mock.transport_callable()
	var api := DmOffline.make_api(mock)
	api.transport = Callable(wire, "call_it")
	var reg := await api.register("ledger", "", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(1)
	var cid := int(ch.data["id"])
	var shell := Shell.new()
	root.add_child(shell)
	var r := DmSessionRewards.new()
	r.auto_tick = false
	r.rng = func() -> float: return 0.0
	r.now_ms = func() -> int: return _clock[0]
	root.add_child(r)
	r.attach_spawner(shell)
	var hero := Node3D.new()
	root.add_child(hero)
	var m := DmRewardsMember.make(cid, 1, hero, api)
	r.add_member(m)
	var failed := []
	r.session_failed.connect(func(why: String) -> void: failed.append(why))
	ok(await r.start(cid) and r.legacy_ledger and r.session_id == "" and failed.is_empty(), "missing /api/sessions falls back to the kill ledger", str(failed))
	for i in 5:
		var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
		e.use_nav = false
		e.with_visual = false
		e.wander_enabled = false
		e.use_avoidance = false
		e.position = Vector3(3, 0, i * 0.2)
		e.set_meta("dm_level", 1)
		root.add_child(e)
		shell.enemy_spawned.emit(e)
		e.take_damage(1e9, hero, false)
	ok(m.stats["kills_earned"] == 5 and m.prog.local["totalKills"] == 0, "kills pending until the ledger answers")
	await r.flush()
	ok(wire.ledger_posts == 1 and m.prog.local["totalKills"] == 5 and m.prog.character["experience"] > 0, "first flush credits kills + XP through the ledger", str(m.stats))
	ok(not m.reporter.has_pending(), "ledger reply acked the batch")
	await r.flush()
	ok(wire.ledger_posts == 1, "an empty flush posts nothing")
	var xp1 := int(m.prog.character["experience"])
	var e2: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e2.use_nav = false
	e2.with_visual = false
	e2.wander_enabled = false
	e2.use_avoidance = false
	e2.position = Vector3(3, 0, 0)
	e2.set_meta("dm_level", 1)
	root.add_child(e2)
	shell.enemy_spawned.emit(e2)
	e2.take_damage(1e9, hero, false)
	await r.end_session({})
	ok(m.prog.local["totalKills"] == 6 and int(m.prog.character["experience"]) > xp1, "end_session flushes the last kill through the ledger", str(m.stats))


func _main() -> void:
	DmSimData.ensure()
	await _spend_race()
	await _roll_serialised()
	await _ledger_fallback()
	print("online_local: %d passed, %d failed" % [_p, _f])
	quit(1 if _f > 0 else 0)
