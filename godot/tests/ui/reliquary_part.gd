extends "res://tests/common/dm_suite_part.gd"
## Reliquary window size is stable (godot --headless --path godot --script res://tests/ui/reliquary_size_run.gd):
## selecting items of any shape must not change the window's size, and all 48 bag cells stay reachable at small and large viewports.

var _pass := 0
var _fail := 0


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
	await _run()


func _rich(n: int) -> Dictionary:
	var stats: Array = []
	for i in n:
		stats.append({"text": "+%d%% damage to the long-named foes of the Drowned Congregation and their many allies" % (i + 3), "fx": "", "necro": i % 2 == 0})
	return {"id": 900 + n, "name": "Warden of the Ascended Gravecaller's Vigil", "rarity": "legendary", "quantity": 1, "sell_value": 400, "type_label": "armor chest",
		"ilvl": 40, "affix_count": n, "stats": stats, "lore": "A very long line of lore. ".repeat(12), "equippable": true}


func _run() -> void:
	for vp in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(1024, 600), Vector2i(2560, 1440)]:
		# a SubViewport of the size under test: the window lays itself out against its own viewport (the headless root is fixed)
		var sv := SubViewport.new()
		sv.size = vp
		sv.disable_3d = true
		root.add_child(sv)
		var r := DmReliquaryPanel.new()
		sv.add_child(r)
		r.has_sell = true
		r.at_grinder = false
		var bag: Array = []
		bag.resize(48)
		for i in 48:
			bag[i] = {}
		bag[0] = {"id": 1, "name": "Ore", "rarity": "common", "quantity": 40, "sell_value": 3, "type_label": "material"}
		bag[1] = _rich(0)
		bag[2] = _rich(4)
		bag[3] = _rich(9)
		r.set_inventory(bag, {}, {})
		r.open()
		await _frames(6)
		var h0 := r.size.y
		var tag := " @%dx%d" % [vp.x, vp.y]
		var heights := [h0]
		for i in [0, 1, 2, 3, 3, 0]:
			r._slots[i].pressed.emit(r._slots[i])
			await _frames(6)
			heights.append(r.size.y)
		for i in [0, 1, 2, 3]:
			r._slots[i].pressed.emit(r._slots[i])
			await _frames(4)
		r.sel_item = {}
		r._render_detail()
		await _frames(6)
		heights.append(r.size.y)
		var uniq := {}
		for h in heights:
			uniq[snappedf(h, 0.5)] = true
		_check(uniq.size() == 1, "window height is the same for every selection%s: %s" % [tag, str(heights)])
		# every bag cell is a laid-out, non-zero control inside the scrollable body
		var ok := true
		for s in r._slots:
			if s.size.x < 40.0 or s.size.y < 40.0:
				ok = false
		_check(ok and r._slots.size() == 48, "all 48 bag cells have their full size%s" % tag)
		# the panel never exceeds the viewport height, and what does not fit is reachable by the body scroll
		_check(r.size.y <= float(vp.y) + 1.0, "window fits the viewport height%s (%s of %d)" % [tag, str(r.size.y), vp.y])
		var last: Control = r._slots[47]
		var body_h := r._content_margin.get_combined_minimum_size().y
		var view_h := r.scroll.size.y
		_check(view_h >= body_h - 0.5 or r.scroll.get_v_scroll_bar().max_value >= body_h - 1.0, "the bag grid stays in the scrollable body%s" % tag)
		_check(last.get_global_rect().size.y > 0.0, "last bag cell exists%s" % tag)
		sv.queue_free()
		await _frames(2)
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
