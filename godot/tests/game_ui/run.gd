extends SceneTree
## DmGameUi against the mock DmGame (no live server):  godot --headless --path godot --script res://tests/game_ui/run.gd

var _fail := 0
var _pass := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func make() -> Array:
	DmUiConfig.dir = ""
	var game := DmMockGame.new()
	root.add_child(game)
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	return [game, ui]


func _key(ui: DmGameUi, code: int) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	ui._unhandled_key_input(e)


func _card(ui: DmGameUi, item_id: String) -> Dictionary:
	for c in ui.inv.panel.bag:
		if not c.is_empty() and c["item_id"] == item_id:
			return c
	for k in ui.inv.panel.worn:
		if ui.inv.panel.worn[k]["item_id"] == item_id:
			return ui.inv.panel.worn[k]
	for k in ui.inv.panel.belt:
		if ui.inv.panel.belt[k]["item_id"] == item_id:
			return ui.inv.panel.belt[k]
	return {}


func _run() -> void:
	var pair := make()
	var game: DmMockGame = pair[0]
	var ui: DmGameUi = pair[1]
	await _frames(3)

	# --- HUD merge ---
	_check(ui.hud.vm.has("hp") and ui.hud.vm.get("level") == 12, "hud fed from game.hud_state")
	_check(ui.hud.vm["reveal"].has("hud.dial"), "held-back elements listed in vm.reveal")
	_check(ui.hud.vm.has("new") and ui.hud.vm.has("grimoire_new"), "ui-owned parts merged")
	game.hud["hp"] = 123
	await _frames(2)
	_check(ui.hud.vm["hp"] == 123, "hud follows game each frame")

	# --- every panel opens by key and closes again ---
	for k in DmGameUi.PANEL_KEYS:
		var p: String = DmGameUi.PANEL_KEYS[k]
		if p == "vault":
			continue
		_key(ui, k)
		await _frames(3)
		_check(ui.is_open(p), "key opens %s" % p)
		_key(ui, k)
		await _frames(2)
		_check(not ui.is_open(p), "key closes %s" % p)
	_key(ui, KEY_ESCAPE)
	await _frames(3)
	_check(ui.is_open("settings"), "Esc with nothing open opens Settings")
	ui.close_panels()
	await _frames(2)
	game.area_id = "chapterhouse"
	_key(ui, KEY_V)
	await _frames(3)
	_check(ui.is_open("vault"), "V opens the vault in the Chapterhouse")
	_check(not game.calls_to("/api/vault/7").is_empty(), "vault read via DmApi")
	ui.close_panels()
	game.area_id = "graves"
	_key(ui, KEY_V)
	await _frames(2)
	_check(not ui.is_open("vault"), "vault refuses outside the safe areas")
	game.area_id = "chapterhouse"

	# --- Reliquary: equip / double-click / right-click / lock / sell ---
	ui.toggle_panel("inventory")
	await _frames(3)
	var ring := _card(ui, "ring_copper")
	_check(not ring.is_empty() and ring["equippable"], "ring card built")
	game.clear_calls()
	ui.inv.panel.equip_toggled.emit(ring)   # double-click
	await _frames(3)
	var eq := game.calls_to("/api/inventory/equip")
	_check(eq.size() == 1 and eq[0]["body"]["slot_index"] == 3 and eq[0]["body"]["equipped"] == 1, "double-click equips via equip_item")
	_check(game.refreshes["inventory"] >= 1, "inventory refreshed after equip")
	var worn := _card(ui, "staff_bone")
	game.clear_calls()
	ui.inv.panel.equip_toggled.emit(worn)
	await _frames(3)
	var un := game.calls_to("/api/inventory/equip")
	_check(un.size() == 1 and un[0]["body"]["equipped"] == 0 and un[0]["body"]["slot_index"] == 105, "unequip a worn piece")
	game.clear_calls()
	ui.inv.panel.slot_right_clicked.emit(_card(ui, "tool_pickaxe_iron"))
	await _frames(3)
	var bt := game.calls_to("/api/inventory/belt")
	_check(bt.size() == 1 and bt[0]["body"]["equipped"] == 1 and bt[0]["body"]["slot_index"] == 2, "right-click a tool puts it on the belt")
	game.clear_calls()
	ui.inv.panel.slot_right_clicked.emit(_card(ui, "elixir_moonlight"))
	await _frames(2)
	_check(DmUiConfig.parse(ui.store.get_item(ui.belt_key())).get("elixir") == "elixir_moonlight", "right-click a brew sets the belt pick")
	var ring2 := _card(ui, "ring_copper")
	ui.inv.panel.lock_toggled.emit(ring2)
	await _frames(1)
	_check(ui.locks.is_locked(ring2["row"]), "lock toggles")
	ui.inv.panel.lock_toggled.emit(ring2)
	game.clear_calls()
	ui.inv.panel.sell_requested.emit(_card(ui, "material_copper_shard"), 1)
	await _frames(3)
	_check(not game.calls_to("/api/inventory/save").is_empty() and not game.calls_to("/api/character/save-progress").is_empty(), "sell saves the bag and credits gold")
	_check(int(game.character["gold"]) == 1502, "sell credits gold")
	game.clear_calls()
	ui.inv.panel.sort_requested.emit()
	await _frames(3)
	_check(not game.calls_to("/api/inventory/save").is_empty(), "sort saves the bag")

	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
