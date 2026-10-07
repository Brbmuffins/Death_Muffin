extends SceneTree
## Online-path regressions that need no live server (the live end-to-end check is tests/online_live, opt-in):
##  1. DmProgressSync.spend_on_server must not lose gold picked up while its pre-save is in flight,
##  2. a failed pre-save must not let the spend go through on stale server gold,
##  (the rebuild's DmSessionRewards ledger-fallback check lives on godot-next only.)
## godot --headless --path godot --script res://tests/online_local/run.gd

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
	_main.call_deferred()


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


func _main() -> void:
	DmSimData.ensure()
	await _spend_race()
	await _roll_serialised()
	print("online_local: %d passed, %d failed" % [_p, _f])
	quit(1 if _f > 0 else 0)
