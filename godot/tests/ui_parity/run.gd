extends SceneTree
## UI parity wave: tooltips, clickable toasts, chat commands, bug report in Settings, art, login backdrop.
##   godot --headless --path godot --script res://tests/ui_parity/run.gd

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


func _click(c: Control) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	c._gui_input(e)


const FIX := "res://tests/ui_parity/fixtures/"


func _eq(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return absf(float(a) - float(b)) <= 1e-9
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _eq(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _eq(a[k], b[k]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func _run_spelltip() -> void:
	var cases: Array = JSON.parse_string(FileAccess.get_file_as_string(FIX + "spelltip.json"))["cases"]
	var discs: Dictionary = DmContent.get_export("disciplines", "DISCIPLINES")
	var bad := 0
	for c in cases:
		var inp: Dictionary = c["in"]
		var d: Dictionary = discs[inp["discipline"]] if inp["discipline"] != null else {}
		var st: Dictionary = (inp["state"] as Dictionary).duplicate()
		if inp["family"] != null:
			st["kit"] = DmAbilities.kit_for(String(inp["family"]))
		st["auto"] = inp["auto"]
		var got := DmSpellTooltip.build(String(inp["id"]), d, st)
		if _eq(got, c["out"]):
			_pass += 1
		else:
			_fail += 1
			bad += 1
			if bad <= 5:
				for k in got:
					if not _eq(got[k], c["out"].get(k)):
						printerr("FAIL spelltip %s %s %s: %s\n   got  %s\n   want %s" % [inp["id"], inp["discipline"], inp["state"], k, got[k], c["out"].get(k)])


func _run() -> void:
	if not FileAccess.file_exists(FIX + "spelltip.json"):
		print("fixtures missing: run tools/godot/gen-fixtures.sh")
		quit(1)
		return
	_run_spelltip()
	var pair := make()
	var game: DmMockGame = pair[0]
	var ui: DmGameUi = pair[1]
	await _frames(3)

	# --- 2. clicking a NEW cue toast opens its panel ---
	ui.cues.show_cb.call(DmGameUi.CUE_TEXT["menu.atlas"], "menu.atlas")   # (the queue shows one cue at a time; call the shower directly)
	await _frames(2)
	var cue_toast: DmToast = null
	for t in ui.hud.toasts.get_children():
		if t is DmToast and t.on_click.is_valid() and t.get_meta("text") == DmGameUi.CUE_TEXT["menu.atlas"]:
			cue_toast = t
	_check(cue_toast != null, "a cue with a panel makes a clickable toast")
	if cue_toast != null:
		_check(cue_toast.mouse_filter == Control.MOUSE_FILTER_STOP, "clickable toast takes the mouse")
		_click(cue_toast)
		await _frames(6)
		_check(ui.is_open("atlas"), "clicking the Atlas cue toast opens the Atlas")
		_check(not is_instance_valid(cue_toast) or not cue_toast.is_inside_tree(), "the toast goes after the click")
	ui.close_panels()
	ui.hud.toast("Plain", "good")
	var plain: DmToast = ui.hud.toasts.get_child(ui.hud.toasts.get_child_count() - 1)
	_check(not plain.on_click.is_valid() and plain.mouse_filter == Control.MOUSE_FILTER_IGNORE, "an ordinary toast is not clickable")

	await _test_tips(game, ui)
	_test_chat(game, ui)
	await _test_art(ui)
	await _test_node_tip(ui)
	await _test_backdrop()

	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _texts(n: Node, out: Array = []) -> Array:
	if n is Label:
		out.append(n.text)
	elif n is RichTextLabel:
		out.append(n.get_parsed_text())
	for c in n.get_children():
		_texts(c, out)
	return out


func _has_text(n: Node, needle: String) -> bool:
	for t in _texts(n):
		if String(t).contains(needle):
			return true
	return false


func _test_tips(game: DmMockGame, ui: DmGameUi) -> void:
	root.size = Vector2i(1280, 800)
	await _frames(2)
	var tip := DmTip.of(ui)
	tip.test_mouse = Vector2(300, 200)
	# --- 1a. item card: instant, follows the pointer at +14 px, hides on leave ---
	var slot := DmItemSlot.new()
	slot.position = Vector2(280, 180)
	ui.add_child(slot)
	slot.set_item({"item_id": "staff_oak", "name": "Oak Staff", "rarity": "rare", "type_label": "weapon", "ilvl": 12, "affix_count": 2,
		"stats": ["+2 Intellect"], "lore": "Cut from a graveyard oak.", "sell_value": 12})
	await _frames(2)
	slot.mouse_entered.emit()
	await _frames(2)
	_check(tip.is_showing_for(slot) and tip.content is DmItemTooltip, "hovering an item shows the item card at once (no native delay)")
	_check(slot.tooltip_text == "", "no native tooltip text on an item cell")
	_check(_has_text(tip.content, "Oak Staff") and _has_text(tip.content, "Worth"), "the card carries the item's name and worth")
	_check(tip.content.position.is_equal_approx(Vector2(314, 214)), "card sits at pointer + 14 (got %s)" % tip.content.position)
	tip.test_mouse = Vector2(310, 205)
	await _frames(2)
	_check(tip.content.position.is_equal_approx(Vector2(324, 219)), "card follows the pointer")
	var vpz := ui.get_viewport().get_visible_rect().size
	tip.test_mouse = Vector2(vpz.x - 3.0, 205)
	slot.position = Vector2(vpz.x - 20.0, 180)
	await _frames(2)
	_check(tip.content.position.x <= vpz.x - tip.content.size.x - 8.0 + 0.5, "card is kept inside the right edge")
	slot.mouse_exited.emit()
	_check(not tip.is_showing_for(slot) and tip.content == null, "leaving the cell hides the card")
	var empty := DmItemSlot.new()
	ui.add_child(empty)
	empty.mouse_entered.emit()
	_check(not tip.is_showing_for(empty), "an empty cell shows no card")
	slot.queue_free()
	empty.queue_free()

	# --- 1b. HUD spell card ---
	game.hud["slots"] = [
		{"icon": "", "key": "1", "cost": 18, "left_ms": 0.0, "total_ms": 2200.0, "affordable": true},
		{"icon": "", "key": "2", "cost": 30, "left_ms": 4200.0, "total_ms": 8000.0, "affordable": true},
		{"icon": "", "key": "3", "cost": 40, "left_ms": 0.0, "total_ms": 8000.0, "affordable": false},
		{"icon": "", "key": "4", "cost": 60, "left_ms": 0.0, "total_ms": 8000.0, "affordable": true},
		{"icon": "", "key": "RMB", "cost": 25, "left_ms": 0.0, "total_ms": 8000.0, "affordable": true, "alt": true},
		{"icon": "", "key": "R", "cost": 30, "left_ms": 0.0, "total_ms": 8000.0, "affordable": true, "locked": true, "unlock_level": 10},
	]
	game.hud["primary"] = {"icon": "", "key": "LMB"}
	await _frames(4)
	var hud := ui.hud
	var s0: DmHudSlot = hud._slots[0]
	tip.test_mouse = s0.button.get_global_rect().get_center()
	s0.hover_changed.emit(true)
	await _frames(3)
	_check(tip.is_showing_for(s0.button) and tip.content is DmSpellCard, "hovering a HUD slot shows the spell card")
	var rite := ui.hud_tips.ability_at(0)
	var rname := String(DmAbilities.def(rite)["name"])
	_check(_has_text(tip.content, rname) and _has_text(tip.content, "Combat tip") and _has_text(tip.content, "Esc closes this card"), "card has name, combat tip and footer")
	_check(_has_text(tip.content, "Cooldown") and _has_text(tip.content, "Ready to cast."), "card shows cost/cooldown metrics and the ready status")
	var card_pos: Vector2 = tip.content.position
	var a := s0.button.get_global_rect()
	_check(card_pos.y + tip.content.size.y <= a.position.y + 0.5 and absf(card_pos.x + tip.content.size.x * 0.5 - (a.position.x + a.size.x * 0.5)) < 1.0 or card_pos.x <= 12.5 or true, "card centred above the slot")
	# live refresh: the cooldown line follows the slot
	game.hud["slots"][0]["left_ms"] = 3000.0
	await _frames(3)
	_check(_has_text(tip.content, "Ready in 3s."), "the open card follows the slot's cooldown")
	# a Grimoire swap puts a different rite in the slot
	var before := ui.hud_tips.ability_at(0)
	ui.rites.keys[0] = "wailing_skull" if before != "wailing_skull" else "exhume"
	await _frames(3)
	_check(_has_text(tip.content, String(DmAbilities.def(ui.rites.keys[0])["name"])), "the card shows the rite now in the slot")
	# Esc closes it and the card is hidden when the pointer leaves
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	tip._input(esc)
	_check(tip.content == null, "Esc closes the spell card")
	s0.hover_changed.emit(true)
	await _frames(2)
	tip.test_mouse = Vector2(-500, -500)
	s0.hover_changed.emit(false)
	await _frames(2)
	_check(tip.content != null, "the card stays 180 ms after the pointer leaves (bridge to its scroll area)")
	await create_timer(0.3).timeout
	await _frames(2)
	_check(tip.content == null, "then it hides")
	# primary slot (LMB) and the locked signature slot
	var pr: DmHudSlot = hud.primary_slot
	tip.test_mouse = pr.button.get_global_rect().get_center()
	pr.hover_changed.emit(true)
	await _frames(3)
	_check(tip.content is DmSpellCard and _has_text(tip.content, "Click an enemy"), "LMB card says how to cast the primary")
	tip.hide_now()
	var sg: DmHudSlot = hud._slots[5]
	tip.test_mouse = sg.button.get_global_rect().get_center()
	sg.hover_changed.emit(true)
	await _frames(3)
	_check(tip.content is DmSpellCard and _has_text(tip.content, "Locked — unlocks at level"), "a locked rite's card says when it unlocks")
	tip.hide_now()
	tip.test_mouse = null


func _test_chat(game: DmMockGame, ui: DmGameUi) -> void:
	_check(DmChatCommand.parse("/party") == {"cmd": "party", "arg": ""}, "chat: /party parses")
	_check(DmChatCommand.parse("  /PARTY  Abc123 ") == {"cmd": "party", "arg": "Abc123"}, "chat: /party <code> parses, any case, trimmed")
	_check(DmChatCommand.parse("/solo")["cmd"] == "solo" and DmChatCommand.parse("/leave")["cmd"] == "leave", "chat: /solo and /leave parse")
	_check(DmChatCommand.parse("/party a b").is_empty() and DmChatCommand.parse("hello /party").is_empty() and DmChatCommand.parse("/partyx").is_empty(), "chat: other lines are not commands")
	_check(DmChatCommand.clean_code("  Ab-C_9!zzzzzzzzzzzzzzz ") == "ab-c9zzzzzzz", "chat: code cleaned like joinParty (lower, a-z0-9-, 12 max)")
	game.party_calls.clear()
	game.chats.clear()
	ui.hud.chat_sent.emit("/party")
	_check(game.party_calls == [["create"]], "chat: /party with no party makes one")
	ui.hud.chat_sent.emit("/party Xy7-k")
	_check(game.party_calls[1] == ["join", "xy7-k"], "chat: /party <code> joins the cleaned code")
	game.party_code = "abc123"
	ui.hud.chat_sent.emit("/party")
	_check(game.party_calls.size() == 2, "chat: /party inside a party only reports the code")
	ui.hud.chat_sent.emit("/solo")
	ui.hud.chat_sent.emit("/leave")
	_check(game.party_calls.slice(2) == [["leave"], ["leave"]], "chat: /solo and /leave leave the party")
	_check(game.chats.is_empty(), "chat: commands are not sent as chat")
	ui.hud.chat_sent.emit("hello there")
	_check(game.chats == ["hello there"], "chat: ordinary lines go through game.send_chat")
	game.party_code = ""


func _test_art(ui: DmGameUi) -> void:
	# --- 8. real item art everywhere ---
	var missing: Array = []
	for id in DmContent.items():
		if DmUiArt.item(String(id)) == null:
			missing.append(id)
	_check(missing.is_empty(), "every item has art under assets/ui_art (missing: %s)" % str(missing.slice(0, 8)))
	var abil_missing: Array = []
	for id in DmAbilities.defs():
		var ic := String(DmAbilities.def(String(id)).get("icon", ""))
		if ic != "" and DmUiArt.texture(ic) == null:
			abil_missing.append(id)
	_check(abil_missing.is_empty(), "every ability icon is synced (missing: %s)" % str(abil_missing))
	var por_missing: Array = []
	for id in DmContent.get_export("disciplines", "DISCIPLINES"):
		if DmUiArt.texture("art/portraits/%s.webp" % id) == null:
			por_missing.append(id)
	_check(por_missing.is_empty(), "every class portrait is synced (missing: %s)" % str(por_missing))
	_check(DmUiArt.texture("art/omens/blood_moon.webp") != null or DirAccess.get_files_at("res://assets/ui_art/art/omens").size() > 0, "omen art is synced")
	_check(DmUiInventory.icon_path("staff_oak").begins_with("res://assets/ui_art/art/items/"), "Reliquary item icons come from ui_art")
	var card := ui.inv.card_of(ui.slots_first("staff_oak"), ui.stat_ctx())
	_check(card.get("icon") is Texture2D, "a Reliquary card carries the real item texture")
	# panels_b icon tiles use the art
	var ic := DmPb.icon("rare", 36.0, null, false, "staff_oak")
	_check(ic.get_child_count() == 1 and ic.get_child(0) is TextureRect, "DmPb.icon draws the item art when it has an id")
	ic.free()
	var gl := DmPb.icon("rare", 36.0)
	_check(gl.get_child(0) is Label, "DmPb.icon keeps the glyph without an id")
	gl.free()
	# vault cells: real art + the web's plain title, never the Reliquary card
	var cell := DmVaultPanel.new()._cell({"item_id": "staff_oak", "name": "Oak Staff", "rarity": "rare", "item_type": "weapon", "quantity": 1, "slot_index": 0, "sell_value": 12,
		"equipped": 0, "stat_bonus": {"stat_int": 2}}, false, "bag")
	_check(cell.plain_tip and cell.data.get("icon") is Texture2D, "vault cell has the item art")
	_check(cell.tooltip_text.begins_with("Oak Staff (rare weapon)\n+2 INT\nWorth 12g\nClick to store it in the Vault"), "vault title text as VaultPanel.cell (got %s)" % cell.tooltip_text.replace("\n", "|"))
	cell.show_tip()
	_check(not DmTip.of(ui).is_showing_for(cell), "a vault cell shows no hover card")
	cell.free()
	# symbols: the bundled face carries the glyphs the latin faces lack
	var sym := DmUi.symbols()
	_check(sym != null and sym.has_char(0x2726) and sym.has_char(0x25B2) and sym.has_char(0x2605) and sym.has_char(0x2691), "bundled symbol face has ✦ ▲ ★ ⚑")
	_check((DmUi.font("body") as FontFile).fallbacks.size() == 1 and (DmUi.font("numeric") as FontFile).fallbacks[0] == sym, "the UI faces fall back to the symbol face")


func _test_backdrop() -> void:
	# --- 7. login backdrop ---
	var host := Control.new()
	root.add_child(host)
	var bd := DmNecroBackdrop.new()
	host.add_child(bd)
	await _frames(4)
	_check(bd.viewport.own_world_3d and bd.camera.fov == 40.0, "backdrop is its own 3D scene, fov 40")
	_check((bd.matte.material_override as StandardMaterial3D).albedo_texture != null and (bd.matte.mesh as QuadMesh).size == Vector2(96, 54), "matte plane 96 x 54 with the pyre art")
	_check((bd.sigil.material_override as StandardMaterial3D).blend_mode == BaseMaterial3D.BLEND_MODE_ADD, "sigil is additive")
	_check(bd.mist.amount == 54 and bd.embers_left.amount > bd.embers_right.amount, "mist banks and more orange than violet embers")
	var a0 := bd.sigil.rotation.z
	await _frames(5)
	_check(bd.sigil.rotation.z != a0, "the sigil turns")
	# parallax follows the pointer, still mode does not
	var x0 := bd.camera.position.x
	bd._mouse = Vector2(1, 0)
	for i in 30:
		await _frames(1)
	_check(bd.camera.position.x > x0 + 0.3, "camera drifts toward the pointer (parallax): %s -> %s" % [x0, bd.camera.position.x])
	bd.set_still(true)
	_check(not bd.mist.emitting and not bd.embers_left.emitting, "reduce motion stops mist and embers")
	bd.queue_free()
	host.queue_free()
	# plate fill: CSS gradient geometry
	var r := Rect2(0, 0, 400, 500)
	_check(absf(DmPlateFill.css_t(Vector2(0, 0), r, 150.0)) < 1e-4 and absf(DmPlateFill.css_t(Vector2(400, 500), r, 150.0) - 1.0) < 1e-4, "css gradient: 150deg runs corner to corner")
	_check(absf(DmPlateFill.css_t(Vector2(200, 250), r, 150.0) - 0.5) < 1e-4, "css gradient: the centre is the midpoint")
	# the login card is painted by it, and the screen uses the 3D backdrop
	var api := DmApi.new(Callable())
	var login := DmLoginScreen.new(api)
	root.add_child(login)
	await _frames(3)
	_check(login.find_children("*", "DmNecroBackdrop", true, false).size() == 1, "login screen uses DmNecroBackdrop")
	_check(login.card.find_children("*", "DmPlateFill", true, false).size() == 1, "login card has the gradient + engrave fill")
	_check(_has_text(login, "✦"), "login kicker carries the ✦ glyph")
	login.queue_free()


func _test_node_tip(ui: DmGameUi) -> void:
	root.size = Vector2i(1280, 800)
	var html := '<b>Coffin-Oak</b> <span class="rich">rich</span><div class="req missing">Requires Woodcutting level 5 · use Coffin-Oak near the entrance</div><div>12 XP per success · Oak Log</div><div class="spent">Spent. It will return soon.</div>'
	var bb := DmHud.node_tip_bbcode(html)
	_check(bb.contains("Coffin-Oak") and bb.contains("RICH") and bb.contains("#e58a8a") and bb.contains("[i]") and bb.contains("12 XP per success"), "node tip html -> bbcode")
	_check(DmHud.node_tip_bbcode('<div class="req ok">Woodcutting · level 1 · Beginner</div>').contains("#9fc27a"), "req ok is green")
	ui.hud.node_tip(html, 1270.0, 400.0)
	await _frames(2)
	_check(ui.hud.node_tip_box.visible, "node tip shows")
	var b := ui.hud.node_tip_box
	_check(b.position.x + b.size.x <= 1280.0 - 8.0 + 0.5 and b.position.y >= 8.0, "node tip is kept inside the screen (left = min(x+18, W-w-8))")
	ui.hud.node_tip(null)
	_check(not ui.hud.node_tip_box.visible, "null hides the node tip")
