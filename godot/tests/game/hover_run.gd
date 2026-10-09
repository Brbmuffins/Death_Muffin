extends SceneTree
## Hover picking (DmGameInput._pick): the mouse over an enemy / boss-less gathering node must make `input.hover` that target (it was always
## null: the pick's running best lived in a lambda, which captures by value), the gather node tip must show, and empty ground clears it.
## godot --headless --path godot --script res://tests/game/hover_run.gd

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


func _on(game: DmGame, x: float, y: float, z: float) -> void:
	var s: Vector2 = game.camera.unproject_position(Vector3(x, y, z))
	game.input.mouse["x"] = s.x
	game.input.mouse["y"] = s.y
	game.input.hover = null


func _run() -> void:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("hv%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 7, "warmup": false})
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	game.ui = ui
	await ui.warm()
	game.dev_access = true
	game.nav.set_unlocked(DmContent.area_order())

	# --- an enemy
	var rect: Dictionary = DmContent.area("graves")["rect"]
	game.player.teleport((float(rect["x0"]) + float(rect["x1"])) / 2.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	game.p["area"] = "graves"
	for i in 240:
		game.p["hp"] = game.player.max_hp()
		await process_frame
	var picked: DmSimEnemy = null
	for e in game.sim.enemies.values():
		if e.state != "dead" and e.state != "rising" and e.state != "burrow":
			picked = e
			break
	_check(picked != null, "an enemy is alive to hover")
	if picked != null:
		_on(game, picked.x, 0.9 * picked.scale, picked.z)
		game.input._pick(game.camera)
		_check(game.input.hover != null and game.input.hover["kind"] == "enemy", "mouse on an enemy -> hover kind enemy")
		# a neighbour can win if it overlaps on screen: the hovered one must be at the same screen spot
		if game.input.hover != null and game.input.hover["kind"] == "enemy":
			var h: DmSimEnemy = game.sim.enemies.get(int(game.input.hover["id"]))
			_check(h != null, "hover id is a live enemy")
			if h != null:
				var a: Vector2 = game.camera.unproject_position(Vector3(h.x, 0.9 * h.scale, h.z))
				_check(a.distance_to(Vector2(game.input.mouse["x"], game.input.mouse["y"])) < 46.0, "hovered enemy is under the mouse")
			_check(game.input.cursor_target().has("enemyId"), "cursor_target aims at the hovered enemy")
			game.input.update_cursor()
		game.views.hover_id = -1
		game.input.hover = null
		game.input._pick_ms = 0
		# far from everything: nothing hovered
		game.input.mouse["x"] = -5000.0
		game.input.mouse["y"] = -5000.0
		game.input._pick(game.camera)
		_check(game.input.hover == null, "mouse far from every target -> no hover")

	# --- a gathering node and its tip
	var arect: Dictionary = DmContent.area("acre")["rect"]
	game.player.teleport((float(arect["x0"]) + float(arect["x1"])) / 2.0, (float(arect["z0"]) + float(arect["z1"])) / 2.0)
	game.p["area"] = "acre"
	for i in 60:
		await process_frame
	game.sim.clear_area("acre")
	var node: Dictionary = {}
	var best := 1e9
	for n in game.input._nodes:
		var d := Vector2(float(n["x"]) - game.player.x, float(n["z"]) - game.player.z).length()
		if d < best and d < 20.0:
			best = d
			node = n
	_check(not node.is_empty(), "a gathering node is near the hero in the Acre")
	if not node.is_empty():
		var kind: String = String(DmGathering.node_def(String(node["type"]))["kind"])
		_on(game, float(node["x"]), 1.6 if kind == "tree" else (0.1 if kind == "pool" else 0.5), float(node["z"]))
		game.input._pick(game.camera)
		var h2: Variant = game.input.hover
		_check(h2 != null and h2["kind"] == "node", "mouse on a gathering node -> hover kind node (got %s)" % str(h2 if h2 == null else h2["kind"]))
		_check(ui.hud.node_tip_box.visible, "the node tip is shown while hovering a node")
		_check(ui.hud.node_tip_rt.text != "", "the node tip has text")
		game.input.mouse["x"] = -5000.0
		game.input.mouse["y"] = -5000.0
		game.input._pick(game.camera)
		_check(game.input.hover == null and not ui.hud.node_tip_box.visible, "leaving the node hides the tip")

	print("hover tests: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
