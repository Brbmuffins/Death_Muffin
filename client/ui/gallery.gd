extends Control
## UI kit gallery: every widget + both first panels, with stub data. Run interactively (`godot --path godot res://ui/gallery.tscn`)
## or capture a page:  godot --path godot res://ui/gallery.tscn -- --page=widgets|settings|reliquary|tabbed|scrolled --out=/path.png [--w=1280 --h=800]

var _page_host: Control
var _out := ""
var _page := ""
var _next_id := 1


func _ready() -> void:
	theme = DmUi.theme()
	var args := _args()
	_page = args.get("page", "")
	_out = args.get("out", "")
	if args.has("w"):
		get_window().size = Vector2i(int(args["w"]), int(args.get("h", "800")))
	var bg := ColorRect.new()
	bg.color = Color("100c16")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_page_host = Control.new()
	_page_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_page_host)
	if _page == "":
		_build_nav()
		_show("widgets")
	else:
		_show(_page)
	if _out != "":
		_capture.call_deferred()


func _args() -> Dictionary:
	var d := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1]
	return d


func _capture() -> void:
	for i in 12:
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out)
	print("saved ", _out, " ", img.get_size())
	get_tree().quit()


func _build_nav() -> void:
	var bar := HBoxContainer.new()
	bar.position = Vector2(8, 4)
	bar.z_index = 100
	add_child(bar)
	for p in ["widgets", "settings", "reliquary", "tabbed"]:
		var b := Button.new()
		b.theme_type_variation = "DmButtonSmall"
		b.text = p.to_upper()
		b.pressed.connect(_show.bind(p))
		bar.add_child(b)


func _show(page: String) -> void:
	for c in _page_host.get_children():
		c.queue_free()
	match page:
		"widgets": _page_widgets()
		"settings": _page_settings()
		"reliquary": _page_reliquary()
		"tabbed": _page_tabbed()
		"scrolled": _page_settings(true)


# --- stub data ---------------------------------------------------------------------------------------------
func _icon(c: Color) -> Texture2D:
	var im := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	for y in 48:
		for x in 48:
			var d := Vector2(x - 24, y - 24).length() / 24.0
			var k := clampf(1.0 - d, 0.0, 1.0)
			var col := c.darkened(0.55).lerp(c.lightened(0.25), k * k)
			col.a = 1.0 if d < 0.8 else clampf((1.0 - d) * 5.0, 0.0, 1.0)
			im.set_pixel(x, y, col)
	return ImageTexture.create_from_image(im)


func _item(nm: String, rarity: String, type_label: String, extra: Dictionary = {}) -> Dictionary:
	var d := {
		"id": _next_id, "item_id": nm.to_snake_case(), "name": nm, "rarity": rarity, "quantity": 1, "type_label": type_label,
		"icon": _icon(DmUi.rarity_color(rarity)), "sell_value": 12 + _next_id * 7, "equippable": true,
	}
	_next_id += 1
	d.merge(extra, true)
	return d


func _bag_items() -> Array:
	var bag: Array = []
	bag.resize(48)
	for i in 48:
		bag[i] = {}
	bag[0] = _item("Grave-Iron Blade", "epic", "weapon", {"ilvl": 22, "affix_count": 2, "verdict": {"kind": "up", "text": "Upgrade for your Gravecaller: +12% (more thrall damage)"}, "verdict_short": "up", "stats": [{"text": "+6 STR", "fx": "→ +18 melee damage"}, {"text": "+4 VIT", "fx": "→ +32 health (+14 thrall health)"}, {"text": "Thralls strike twice on corpses", "necro": true}], "lore": "Pulled from a grave that did not want to give it up.", "sell_value": 340})
	bag[1] = _item("Bone Needle Focus", "rare", "weapon", {"ilvl": 17, "affix_count": 1, "stats": [{"text": "+5 INT", "fx": "→ +10% spell power"}], "sell_value": 120, "verdict": {"kind": "down", "text": "Downgrade for your Gravecaller: -4%"}})
	bag[2] = _item("Tattered Cowl", "common", "head armor", {"stats": ["+2 VIT"], "sell_value": 6, "locked": true})
	bag[3] = _item("Grave Dust", "common", "material", {"quantity": 37, "glyph": "◆", "sell_value": 2, "equippable": false})
	bag[4] = _item("Ashen Greaves", "uncommon", "legs armor", {"stats": ["+3 AGI", "+3 VIT"], "sell_value": 28, "is_new": true})
	bag[5] = _item("Ember Elixir", "uncommon", "flask", {"quantity": 4, "equippable": false, "brew_line": "Elixir: +12% spell power for 3 min. Belt key Z.", "sell_value": 18})
	bag[6] = _item("Bell-Warden's Mantle", "legendary", "chest armor", {"ilvl": 30, "affix_count": 3, "stats": [{"text": "+9 VIT", "fx": "→ +72 health"}, {"text": "+7 STR"}], "set_line": "Bell Warden set: 2 of 5 worn", "lore": "It still rings when the dead walk near.", "sell_value": 900, "verdict": {"kind": "up", "text": "Upgrade: +21% survivability"}})
	bag[7] = _item("Plague-Spade", "rare", "tool", {"equippable": false, "belt_kind": "spade", "sell_value": 55})
	bag[9] = _item("Rusted Ring", "common", "ring", {"stats": ["+1 AGI"], "sell_value": 4})
	bag[10] = _item("Wraith Silk", "rare", "material", {"quantity": 12, "equippable": false, "sell_value": 22})
	bag[12] = _item("Mourner's Brooch", "epic", "trinket", {"ilvl": 20, "affix_count": 2, "stats": ["+6 INT", "+3 VIT"], "sell_value": 260, "is_new": true})
	bag[17] = _item("Hollow Shield", "uncommon", "offhand", {"stats": ["+4 VIT"], "sell_value": 30})
	bag[20] = _item("Charnel Gloves", "common", "hands armor", {"stats": ["+1 STR"], "sell_value": 5})
	bag[21] = _item("Salt Flask", "common", "flask", {"quantity": 9, "equippable": false, "sell_value": 3})
	return bag


func _worn() -> Dictionary:
	return {
		"head": _item("Gravecaller Hood", "rare", "head armor", {"stats": ["+4 INT"], "equipped": true}),
		"chest": _item("Shroud of Ash", "epic", "chest armor", {"stats": ["+8 VIT"], "equipped": true, "set_line": "Ashen Rite set: 3 of 5 worn"}),
		"main_hand": _item("Marrow Staff", "rare", "weapon", {"stats": ["+6 INT"], "equipped": true}),
		"ring": _item("Signet of Bone", "uncommon", "ring", {"equipped": true}),
		"feet": _item("Gravewalkers", "common", "feet armor", {"equipped": true}),
	}


func _belt() -> Dictionary:
	return {"hatchet": _item("Iron Hatchet", "common", "tool", {"equippable": false}), "pickaxe": _item("Iron Pickaxe", "uncommon", "tool", {"equippable": false})}


# --- pages ---------------------------------------------------------------------------------------------------
func _col(x: float, w: float) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.position = Vector2(x, 40)
	v.custom_minimum_size.x = w
	v.add_theme_constant_override("separation", 10)
	_page_host.add_child(v)
	return v


func _cap(t: String) -> Label:
	var l := DmUi.label(DmUi.upper(t), "DmKicker")
	return l


func _page_widgets() -> void:
	# column 1: controls + typography
	var c1 := _col(20, 420)
	c1.add_child(_cap("Buttons"))
	var r := HBoxContainer.new()
	for spec in [["Button", "Button", false], ["Small", "DmButtonSmall", false], ["Primary", "DmButtonPrimary", false], ["Disabled", "Button", true]]:
		var b := Button.new()
		b.text = DmUi.upper(spec[0])
		b.theme_type_variation = spec[1]
		b.disabled = spec[2]
		r.add_child(b)
	c1.add_child(r)
	var r2 := HBoxContainer.new()
	var ib := DmIconButton.new()
	r2.add_child(ib)
	var ib2 := DmIconButton.new()
	ib2.glyph = "up"
	r2.add_child(ib2)
	var bt := Button.new()
	bt.theme_type_variation = "DmBackTop"
	bt.text = DmUi.upper("↑ Back to top")
	r2.add_child(bt)
	c1.add_child(r2)
	c1.add_child(_cap("Tabs"))
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	var grp := ButtonGroup.new()
	for i in 3:
		var t := DmTabButton.new()
		t.setup(["Reliquary", "Legion", "Sheet"][i], ["I", "Y", "J"][i])
		t.button_group = grp
		if i == 0:
			t.button_pressed = true
		tabs.add_child(t)
	c1.add_child(tabs)
	c1.add_child(_cap("Inputs"))
	var ob := OptionButton.new()
	for t2 in ["High (bloom, shadows)", "Low (fast)"]:
		ob.add_item(t2)
	c1.add_child(ob)
	var cb_row := HBoxContainer.new()
	cb_row.add_theme_constant_override("separation", 20)
	var cb1 := CheckBox.new()
	cb1.text = "Checked"
	cb1.button_pressed = true
	cb_row.add_child(cb1)
	var cb2 := CheckBox.new()
	cb2.text = "Unchecked"
	cb_row.add_child(cb2)
	c1.add_child(cb_row)
	var sl := HSlider.new()
	sl.min_value = 0
	sl.max_value = 1
	sl.step = 0.05
	sl.value = 0.65
	c1.add_child(sl)
	var le := LineEdit.new()
	le.placeholder_text = "code"
	c1.add_child(le)
	var kr := HBoxContainer.new()
	for k in ["WASD", "I C M", "Shift+Click", "F3"]:
		kr.add_child(DmUi.kbd(k))
	c1.add_child(kr)
	var pb := ProgressBar.new()
	pb.value = 60
	pb.show_percentage = false
	pb.custom_minimum_size.y = 6
	c1.add_child(pb)
	c1.add_child(_cap("Typography"))
	c1.add_child(DmUi.label("RELIQUARY", "DmTitle"))
	c1.add_child(DmUi.label("DIFFICULTY", "DmH3"))
	c1.add_child(DmUi.label("A settings note reads at fifteen pixels in bone.", "DmNote"))
	c1.add_child(DmUi.label("Muted label · faint hint · numeric 1,240g", "DmMuted"))
	c1.add_child(DmUi.label("Something went wrong (error text)", "DmError"))

	# column 2: slots + item tooltips
	var c2 := _col(480, 420)
	c2.add_child(_cap("Item slots"))
	var grid := GridContainer.new()
	grid.columns = 8
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	var samples := [
		_item("A", "common", "x", {}), _item("B", "uncommon", "x", {"quantity": 12}), _item("C", "rare", "x", {"equipped": true}),
		_item("D", "epic", "x", {"locked": true}), _item("E", "legendary", "x", {"is_new": true}), _item("F", "rare", "x", {"verdict": "up"}),
		_item("G", "epic", "x", {"verdict": "down", "quantity": 3}), _item("H", "uncommon", "x", {}), {}, {},
	]
	for i in samples.size():
		var s := DmItemSlot.new()
		s.custom_minimum_size = Vector2(48, 48)
		s.set_item(samples[i])
		if i == 7:
			s.selected = true
		grid.add_child(s)
	c2.add_child(grid)
	c2.add_child(_cap("Equipment + belt empty states"))
	var er := HBoxContainer.new()
	er.add_theme_constant_override("separation", 7)
	for id in ["head", "ring", "main_hand"]:
		var s2 := DmItemSlot.new()
		s2.kind = DmItemSlot.Kind.EQUIP
		s2.custom_minimum_size = Vector2(56, 56)
		s2.empty_glyph = DmReliquaryPanel.EQUIP[id][1]
		s2.empty_label = DmReliquaryPanel.EQUIP[id][0]
		er.add_child(s2)
	for k in ["Hatchet", "Rod"]:
		var s3 := DmItemSlot.new()
		s3.kind = DmItemSlot.Kind.BELT
		s3.custom_minimum_size = Vector2(39, 39)
		s3.empty_label = k
		er.add_child(s3)
	c2.add_child(er)
	c2.add_child(_cap("Item tooltip cards"))
	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", 12)
	var bag := _bag_items()
	for idx in [0, 3]:
		var tt := DmItemTooltip.make(bag[idx])
		tt.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		tr.add_child(tt)
	c2.add_child(tr)

	# column 3: counsel card, toasts, banner, floating numbers
	var c3 := _col(920, 340)
	c3.add_child(_cap("Counsel tip card"))
	var tip := DmTipCard.new()
	tip.set_tip("Open your Reliquary", "Press <kbd>I</kbd> to open the <b>Reliquary</b>. Double-click a piece to equip it; <kbd>Shift+Click</kbd> casts without moving.", 0)
	c3.add_child(tip)
	c3.add_child(_cap("Toasts"))
	for spec2 in [["Damage empowered: +12%", "good"], ["The Sexton refuses.", "err"], ["Picked up Grave Dust ×3", "loot"], ["Legendary: Bell-Warden's Mantle", "loot_major"], ["Waystones unlocked", "new_cue"]]:
		var t3 := DmToast.make(spec2[0], spec2[1], 9999.0)
		c3.add_child(t3)
	c3.add_child(_cap("Banner + combat numbers"))
	var bn := DmBanner.make("Hollow Graves", "The dead remember", 9999.0)
	bn.modulate.a = 1.0
	var bnc := Control.new()
	bnc.custom_minimum_size = Vector2(360, 120)
	bn.set_anchors_preset(Control.PRESET_FULL_RECT)
	bnc.add_child(bn)
	bn.scale = Vector2(0.62, 0.62)
	bn.position = Vector2(-10, 0)
	c3.add_child(bnc)
	var nr := HFlowContainer.new()
	nr.add_theme_constant_override("h_separation", 14)
	for k in [["482", "hit"], ["1,903", "crit"], ["+12", "heal"], ["+40", "ward"], ["31", "dot"], ["-77", "hurt"], ["+25g", "gold"], ["+3 shards", "shard"], ["+90 xp", "xp"], ["Bone Needle", "skill"], ["LEVEL UP", "big"], ["Chain x4", "info"]]:
		var nl := Label.new()
		nl.text = k[0]
		DmFloatingNumber.apply_style(nl, k[1])
		nr.add_child(nl)
	c3.add_child(nr)


func _page_settings(scrolled: bool = false) -> void:
	var w := DmSettingsPanel.new()
	_page_host.add_child(w)
	w.build()
	w.open()
	if scrolled:
		await get_tree().create_timer(0.3).timeout
		w.scroll.scroll_vertical = 600


func _page_reliquary() -> void:
	var w := DmReliquaryPanel.new()
	_page_host.add_child(w)
	w.set_stats_line([
		{"label": "STR", "value": 14, "plus": 6}, {"label": "AGI", "value": 9, "plus": 0}, {"label": "INT", "value": 22, "plus": 4},
		{"label": "VIT", "value": 17, "plus": 4}, {"label": "Health", "value": 412}, {"label": "Spell", "value": 168},
	])
	var bag := _bag_items()
	var worn := _worn()
	var belt := _belt()
	w.junk_count = 5
	w.junk_gold = 61
	w.legion_flag = true
	w.set_inventory(bag, worn, belt)
	# a few stub behaviours so the gallery is interactive
	w.lock_toggled.connect(func(it: Dictionary) -> void:
		it["locked"] = not it.get("locked", false)
		w.refresh())
	w.sort_requested.connect(func() -> void:
		var items := w.bag.filter(func(d: Dictionary) -> bool: return not d.is_empty())
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return DmUi.RARITY_ORDER.find(a["rarity"]) > DmUi.RARITY_ORDER.find(b["rarity"]))
		var nb: Array = []
		nb.resize(48)
		for i in 48:
			nb[i] = items[i] if i < items.size() else {}
		w.set_inventory(nb, w.worn, w.belt))
	w.open()
	if _page == "reliquary" and _args().get("select", "") != "":
		await get_tree().create_timer(0.2).timeout
		w.sel_item = bag[int(_args()["select"])]
		w.refresh()


func _page_tabbed() -> void:
	var w := DmTabbedWindow.new()
	w.title = "Acre"
	w.aka = "P"
	w.panel_width = 640
	_page_host.add_child(w)
	for t in [["skills", "Skills", "P"], ["garden", "Garden", "U"], ["labor", "Laborers", "H"], ["contracts", "Contracts", "O"]]:
		var v := VBoxContainer.new()
		for i in 14:
			v.add_child(DmUi.label("%s row %d: some stub text that lives in the scrolling body under the fixed tabs." % [t[1], i + 1], "DmRow"))
		w.add_tab(t[0], t[1], v, t[2])
	w.set_new("garden", true)
	w.open()
