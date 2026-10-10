extends SceneTree
## Runner shell for ONE-boss scenario suites (tests/next_combat_odds extends it): boots the api, then hands `_parts()` a harness-backed game.
## All the logic lives in harness.gd (the boss suite's shared harness); this file only forwards the handful of members a scenario suite uses.
## The boss suite itself is run.gd.

const H := preload("res://tests/next_bosses/harness.gd")

var h := H.new()
var log_ := H.ErrLog.new()
var mock: DmMockBackend   ## must outlive the suite: the api's transport is its callable
var api: DmApi:
	get: return h.api
	set(v): h.api = v
var character: Dictionary:
	get: return h.character
	set(v): h.character = v
var g: DmNextGame:
	get: return h.g
var hb: DmHeroBody:
	get: return h.hb
var boss: DmBoss:
	get: return h.boss
	set(v): h.boss = v
var boss_id: String:
	get: return h.boss_id
	set(v): h.boss_id = v
var passed: int:   ## read AND written by scenario suites (next_clarity adds its part's counts): GDScript ignores writes to a getter-only property
	get: return h.passed
	set(v): h.passed = v
var failed: int:
	get: return h.failed
	set(v): h.failed = v


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	OS.add_logger(log_)
	log_.suite = h
	h.tree = self
	h.root = root
	h.physics_frame = physics_frame
	h.log_ = log_
	h.PORT = DmTestPorts.free_port()
	mock = DmOffline.make_mock("")
	h.api = DmOffline.make_api(mock)
	var r := await h.api.register("boss%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	h.api.set_token(r.data["token"])
	var c := await h.api.load_or_create_character(2)
	h.character = c.data
	await _parts()
	h.check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), ", ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [h.passed, h.failed])
	quit(1 if h.failed > 0 else 0)


## Overridden by the suite.
func _parts() -> void:
	pass


func check(ok: bool, what: String) -> void:
	h.check(ok, what)


func ticks(n: int) -> void:
	await h.ticks(n)


func until(cond: Callable, limit_s: float) -> bool:
	return await h.until(cond, limit_s)


func new_solo() -> void:
	await h.new_solo()


func summon(shards: int = 20) -> String:
	return h.summon(shards)


func step(secs: float) -> void:
	h.step(secs)


func put(p: Vector3) -> void:
	h.put(p)


func arena() -> Vector3:
	return h.arena()


func end_fight() -> void:
	await h.end_fight()


func perf_info(cond: bool, what: String) -> void:
	h.perf_info(cond, what)
