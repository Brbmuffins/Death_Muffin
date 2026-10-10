extends SceneTree
## Report of the first-combat-frame stall (timing is printed as INFO, never asserted): the first frame with the HUD attached used to cost ~85-125 ms headless (first
## HUD apply: hotbar, textures, label shaping; first control-tree layout) vs ~7 ms steady. DmGameUi.setup now applies the HUD once and
## DmGameUi.warm() takes the first layout frames while loading (DmNextGame.start does both). Headless, warmup on.
## godot --headless --path godot --script res://tests/perf/first_frame_run.gd
## Old budget, now informational only: 35 ms for the first frame after warm() (measured ~3-4 ms; the stall was 85+).

const BUDGET_MS := 35.0
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

func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("ff%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "waves": false, "audio": false, "warmup": true})   # builds + warms the HUD (DmGameUi) under the cover
	var ui := game.ui
	_check(ui != null and not ui._vm.is_empty(), "setup applies the HUD once (first apply must not land in a played frame)")
	var t := Time.get_ticks_usec()
	await process_frame
	var first := (Time.get_ticks_usec() - t) / 1000.0
	print("FIRSTFRAME first=%.1fms budget=%.0fms" % [first, BUDGET_MS])
	perf_info(first < BUDGET_MS, "first frame with the HUD attached under %.0f ms (got %.1f)" % [BUDGET_MS, first])
	game.queue_free()
	await process_frame
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
