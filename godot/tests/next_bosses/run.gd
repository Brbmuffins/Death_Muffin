extends SceneTree
## Suite for godot/next/bosses: the framework + all seven bosses in ONE process. godot --headless --path godot --script res://tests/next_bosses/run.gd
## The api is booted once, the solo game is booted once (the first part boots it, every next boss RESETS it), then ONE host + client ENet pair is booted
## (each boss is summoned on it in turn). Each `<boss>_part.gd` extends harness.gd and holds that boss's own checks:
##   solo()  the boss's fight on the solo game (numbers, telegraph timing, phases, adds, summon rules, defeat -> rewards + report, wipe, rites)
##   net()   what only that boss replicates over two peers (the generic replication, the thrall rules and the one crowd perf probe run once, in the Gravedigger's)
## BOSS_ONLY=mire,saint runs just those parts (development). BOSS_TRACE=1 prints every check as it runs.

const H := preload("res://tests/next_bosses/harness.gd")
## The order matters a little: the Gravedigger first (it owns the fresh-backend checks and the shared probes); the Prelate last (it switches the progression to local).
const PARTS := ["gravedigger", "abbess", "congregation", "mire", "regent", "saint", "prelate"]

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("FAIL: ", what)


func _run() -> void:
	var log_ := H.ErrLog.new()
	OS.add_logger(log_)
	var mock := DmOffline.make_mock("")   # must outlive the suite: the api's transport is its callable
	var api := DmOffline.make_api(mock)
	var r := await api.register("boss%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var ctx := {"tree": self, "root": root, "physics_frame": physics_frame, "api": api, "character": c.data, "log_": log_, "evs": [], "hurts": [],
		"PORT": DmTestPorts.free_port(), "g": null, "hb": null, "hg": null, "cg": null, "g_director_on": true}
	var only := OS.get_environment("BOSS_ONLY").split(",", false)
	var parts: Array = []
	for id in PARTS:
		if only.is_empty() or only.has(id):
			var p: H = load("res://tests/next_bosses/%s_part.gd" % id).new()
			parts.append(p)
	# ---- A: every boss's fight on the one solo game
	for p: H in parts:
		var e0 := log_.errors.size()
		p.adopt(ctx)
		log_.suite = p
		await p.solo()
		p.export_to(ctx)
		_check(log_.errors.size() == e0, "%s: no engine errors in the log (%d: %s)" % [p.boss_id, log_.errors.size() - e0, " || ".join(log_.errors.slice(e0, e0 + 3))])
	if ctx["g"] != null and is_instance_valid(ctx["g"]):
		(ctx["g"] as Node).queue_free()
	ctx["g"] = null
	await physics_frame
	# ---- B: the one two-peer pair, every boss summoned on it in turn
	var net_order := parts.duplicate()   # the Gravedigger last: its replay_pits check plays one extra event on the client, which the others' once-per-peer checks would see
	if net_order.size() > 1 and net_order[0].boss_id == "gravedigger":
		net_order.append(net_order.pop_front())
	for p: H in net_order:
		var e0 := log_.errors.size()
		p.adopt(ctx)
		log_.suite = p
		await p.net()
		p.export_to(ctx)
		_check(log_.errors.size() == e0, "%s: no engine errors in the log during the two-peer run (%d: %s)" % [p.boss_id, log_.errors.size() - e0, " || ".join(log_.errors.slice(e0, e0 + 3))])
	if not parts.is_empty():
		parts[0].adopt(ctx)
		await parts[0].net_down()
	for p: H in parts:
		_passed += p.passed
		_failed += p.failed
		print("%s: %d passed, %d failed" % [p.boss_id, p.passed, p.failed])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)
