extends SceneTree
## UI kit behaviour tests (headless):  godot --headless --path godot --script res://tests/ui/run.gd

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


func _run() -> void:
	# markup -> BBCode
	var bb := DmUi.markup("Press <kbd>I</kbd> for the <b>Reliquary</b> &amp; more[x]")
	_check(bb.contains("[bgcolor") and bb.contains("[b]") and bb.contains("& more") and bb.contains("[lb]x]"), "markup conversion")
	_check(DmUi.gold(1234567) == "1,234,567g", "gold format")
	_check(DmUi.rarity_color("legendary") == Color("ff9a2e"), "rarity colour")

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(root)
	await _frames(2)

	# window: fixed header, back-to-top after 120 px, hides 2 s after scrolling stops, Esc closes
	var w := DmWindow.new()
	w.title = "Test"
	root.add_child(w)
	for i in 60:
		w.body.add_child(DmUi.label("row %d" % i, "DmRow"))
	w.open()
	await _frames(6)
	_check(w.visible, "window opens")
	_check(w.scroll.get_v_scroll_bar().max_value > 400.0, "body is taller than the viewport and scrolls")
	_check(not w.back_to_top_visible(), "back-to-top hidden at the top")
	w.scroll.scroll_vertical = 100
	await _frames(2)
	_check(not w.back_to_top_visible(), "back-to-top still hidden under 120 px")
	w.scroll.scroll_vertical = 300
	await _frames(2)
	_check(w.back_to_top_visible(), "back-to-top shown after 120 px")
	await create_timer(2.6).timeout
	_check(not w.back_to_top_visible(), "back-to-top hides 2 s after scrolling stops")
	w.scroll.scroll_vertical = 200   # a different value than before: the canvas is now >= 900 high, so 300 and 400 may both clamp to the same max
	await _frames(2)
	_check(w.back_to_top_visible(), "back-to-top returns on the next scroll")
	w.scroll.scroll_vertical = 0
	await _frames(2)
	_check(not w.back_to_top_visible(), "back-to-top hides when back at the top")
	var head_y := w.head.get_global_rect().position.y
	w.scroll.scroll_vertical = 500
	await _frames(2)
	_check(is_equal_approx(w.head.get_global_rect().position.y, head_y), "header does not move while the body scrolls")
	var closed_n := [0]
	w.closed.connect(func() -> void: closed_n[0] += 1)
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(2)
	_check(not w.visible and closed_n[0] == 1, "Esc closes the topmost window")

	# stacking: Esc closes only the top window
	var a := DmWindow.new()
	var b := DmWindow.new()
	root.add_child(a)
	root.add_child(b)
	a.open()
	b.open()
	await _frames(3)
	Input.parse_input_event(ev)
	await _frames(2)
	_check(a.visible and not b.visible, "Esc closes only the top of two windows")
	a.close()

	# tabbed window
	var t := DmTabbedWindow.new()
	root.add_child(t)
	var c1 := Label.new()
	var c2 := Label.new()
	t.add_tab("one", "One", c1, "P")
	t.add_tab("two", "Two", c2)
	t.open()
	await _frames(3)
	_check(c1.visible and not c2.visible, "first tab shows first")
	t.select_tab("two")
	_check(not c1.visible and c2.visible and t.active == "two", "tab switch swaps content")
	t.close()

	# reliquary: select, equip signal, junk confirm
	var r := DmReliquaryPanel.new()
	root.add_child(r)
	var bag: Array = []
	bag.resize(48)
	for i in 48:
		bag[i] = {}
	bag[0] = {"id": 1, "name": "Blade", "rarity": "epic", "quantity": 1, "sell_value": 10, "type_label": "weapon"}
	r.junk_count = 2
	r.junk_gold = 20
	r.set_inventory(bag, {}, {})
	r.open()
	await _frames(4)
	var got := []
	r.selected.connect(func(it: Dictionary) -> void: got.append(it))
	r._slots[0].pressed.emit(r._slots[0])
	_check(got.size() == 1 and got[0]["id"] == 1, "slot press selects the item")
	r._slots[0].pressed.emit(r._slots[0])
	_check(r.sel_item.is_empty(), "second press deselects")
	r.confirm_junk = true
	r._render_tools()
	await _frames(2)
	_check(r._tools.get_child_count() == 3, "junk confirm shows text + Sell them + Cancel")

	# settings: change signal + difficulty note
	var s := DmSettingsPanel.new()
	root.add_child(s)
	s.build()
	s.open()
	await _frames(3)
	var seen := {}
	s.changed.connect(func(k: String, v: Variant) -> void: seen[k] = v)
	s._put("vol_music", 0.25)
	_check(seen.get("vol_music") == 0.25, "settings emits changed")
	_check(s.values["vol_music"] == 0.25, "settings keeps values")

	# toast / banner / floating number build without error
	root.add_child(DmToast.make("hi", "good", 0.1))
	root.add_child(DmBanner.make("Area", "sub", 0.1))
	DmFloatingNumber.spawn(root, Vector2(100, 100), "12", "crit")
	await _frames(3)

	print("ui tests: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
