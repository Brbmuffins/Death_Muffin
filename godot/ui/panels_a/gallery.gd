extends Control
## Panels-A gallery: every panel with mock data (DmPaMock). Interactive:  godot --path godot res://ui/panels_a/gallery.tscn
## Capture:  godot --path godot res://ui/panels_a/gallery.tscn -- --pages=ascension,class,... --dir=/abs/shots [--w=1280 --h=900]
## (rendering: see ui/panels_a/shoot.sh, which takes the renderer lock). Pages: see PAGES.

const PAGES := [
	"ascension", "ascension_confirm", "class", "sheet", "cosmetics", "legion", "grimoire", "grimoire_runes", "grimoire_legion",
	"codex_rites", "codex_disciplines", "codex_sets", "codex_affixes", "codex_runes", "codex_altar", "codex_dead", "codex_diocese", "codex_professions", "codex_chronicle",
	"atlas_best", "atlas_slot", "atlas_where", "atlas_set", "atlas_detail", "atlas_mats", "dialogue", "dialogue_topics", "waystones",
]

var _host: Control
var _dir := ""
var _pages: Array = []
var _windows: Array = []


func _ready() -> void:
	theme = DmUi.theme()
	var args := _args()
	if args.has("w"):
		get_window().size = Vector2i(int(args["w"]), int(args.get("h", "900")))
	var bg := ColorRect.new()
	bg.color = Color("100c16")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_host = Control.new()
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_host)
	_dir = String(args.get("dir", ""))
	if args.has("pages"):
		_pages = String(args["pages"]).split(",") if args["pages"] != "all" else PAGES.duplicate()
	if _dir != "":
		_capture_all.call_deferred()
	else:
		_nav()
		show_page(String(args.get("page", "ascension")))


func _args() -> Dictionary:
	var d := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1]
	return d


func _nav() -> void:
	var ob := OptionButton.new()
	ob.position = Vector2(8, 4)
	ob.z_index = 100
	for p in PAGES:
		ob.add_item(p)
	ob.item_selected.connect(func(i: int) -> void: show_page(PAGES[i]))
	add_child(ob)


func _capture_all() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	for p in _pages:
		show_page(String(p))
		for i in 14:
			await get_tree().process_frame
		await get_tree().create_timer(0.6).timeout
		var img := get_viewport().get_texture().get_image()
		var out := "%s/%s.png" % [_dir, p]
		img.save_png(out)
		print("saved ", out, " ", img.get_size())
	get_tree().quit()


func clear_page() -> void:
	for c in _host.get_children():
		_host.remove_child(c)
		c.queue_free()


func show_page(page: String) -> Node:
	clear_page()
	var node: Node = null
	match page:
		"ascension": node = _ascension(false)
		"ascension_confirm": node = _ascension(true)
		"class": node = _class()
		"sheet": node = _sheet()
		"cosmetics": node = _cosmetics()
		"legion": node = _legion()
		"grimoire": node = _grimoire(false, false)
		"grimoire_runes": node = _grimoire(true, false)
		"grimoire_legion": node = _grimoire(false, true)
		"dialogue": node = _dialogue(false)
		"dialogue_topics": node = _dialogue(true)
		"waystones": node = _waystones()
		_:
			if page.begins_with("codex_"):
				node = _codex(page.substr(6))
			elif page.begins_with("atlas_"):
				node = _atlas(page.substr(6))
	return node


func _add(w: Node) -> Node:
	_host.add_child(w)
	return w


func _ascension(confirm: bool) -> Node:
	var w := DmAscensionPanel.new()
	_add(w)
	w.set_state(DmPaMock.ascension_state())
	w.open_altar()
	if confirm:
		w.local["vows"] = w.local["vows"]
		DmPa.find_act(w, "ascend").pressed.emit()
	w.vows_swear_requested.connect(func(v: Dictionary) -> void:
		w.local["vows"] = v
		w.set_state(w.local))
	w.boon_buy_requested.connect(func(id: String) -> void:
		w.local["boons"][id] = int(w.local["boons"].get(id, 0)) + 1
		w.local["ashes"] = int(w.local["ashes"]) - DmAscension.boon_cost(id, w.local["boons"])
		w.set_state(w.local))
	return w


func _class() -> Node:
	var w := DmClassPanel.new()
	_add(w)
	w.set_data(2)
	w.open()
	w.class_chosen.connect(func(i: int) -> void:
		w.begin_saving()
		await get_tree().create_timer(1.0).timeout
		w.fail("The Chapterhouse door is stuck (mock error)."))
	return w


func _sheet() -> Node:
	var w := DmCharacterWindow.new()
	_add(w)
	w.sheet.set_data(DmPaMock.sheet())
	w.cosmetics.set_view(DmPaMock.cosmetics_view())
	w.open_tab("stats")
	return w


func _cosmetics() -> Node:
	var w := DmCharacterWindow.new()
	_add(w)
	w.sheet.set_data(DmPaMock.sheet())
	var v := DmPaMock.cosmetics_view()
	w.cosmetics.set_view(v)
	w.cosmetics.set_charm_counts({"charm_grave_rat": 1})
	w.open_tab("pets")
	return w


func _legion() -> Node:
	var w := DmGrimoireWindow.new()
	_add(w)
	w.grimoire.set_state(DmPaMock.grimoire_state())
	w.legion.set_data(DmPaMock.legion())
	w.open_tab("legion")
	return w


func _grimoire(with_runes: bool, legion_tab: bool) -> Node:
	var w := DmGrimoireWindow.new()
	_add(w)
	w.grimoire.set_state(DmPaMock.grimoire_state())
	if with_runes:
		w.grimoire.set_runes(DmPaMock.runes())
		w.grimoire.selected = 0
	w.legion.set_data(DmPaMock.legion())
	w.grimoire.assign_requested.connect(func(slot: int, id: String) -> void:
		var st: Dictionary = w.grimoire.state
		var keys: Array = st["rites"]["keys"]
		var from := keys.find(id)
		if from >= 0:
			keys[from] = keys[slot]
		keys[slot] = id
		w.grimoire.set_state(st))
	w.open_tab("grimoire")
	w.grimoire.open_session()
	if with_runes:
		w.grimoire.select_socket(0)
	return w


func _codex(tab: String) -> Node:
	var w := DmCodexPanel.new()
	_add(w)
	w.set_discipline("gravecaller")
	w.set_journal(["robber", "hound", "penitent", "sac", "deacon", "gravedigger"], ["chapterhouse", "acre", "graves", "warren", "ossuary"])
	w.set_runes_found(["rune_splinter", "rune_volley"])
	w.set_met_npcs(["prior"])
	w.set_chronicle(DmPaMock.chronicle())
	w.select_tab(tab)
	w.open()
	w.atlas_requested.connect(func() -> void: print("atlas requested"))
	return w


func _atlas(view: String) -> Node:
	var w := DmAtlasPanel.new()
	_add(w)
	DmAtlasPanel.memory["where"] = "graves"
	w.set_context(DmPaMock.atlas_context())
	w.open_atlas()
	match view:
		"best": w.set_view("best")
		"slot": w.set_view("slot")
		"where": w.set_view("where")
		"set": w.set_view("set")
		"mats": w.set_view("mats")
		"detail":
			w.set_view("slot")
			w.select_item("set_gravecaller_head")
	return w


func _dialogue(topics: bool) -> Node:
	var w := DmDialoguePanel.new()
	_add(w)
	w.position = Vector2(360, 64)
	w.source = DmMockSource.new()
	w.open_npc("prior")
	if topics:
		w.go("about")
	return w


func _waystones() -> Node:
	var w := DmWaystonePanel.new()
	_add(w)
	w.set_unlocked(["chapterhouse", "graves", "ossuary", "nave", "sanctum"])
	w.open()
	return w
