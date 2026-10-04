extends Control
## panels_b gallery: every crafting / gathering / economy panel with mock data (DmPbMock). Interactive:
##   godot --path godot res://ui/panels_b/gallery.tscn
## One page to a PNG:  ... -- --page=<name> --out=/path.png [--w=1280 --h=800] [--scroll=300]
## Pages: contracts garden labor skills forge cauldron kiln reforge report shelf salvage vault acre

const PAGES := ["contracts", "garden", "labor", "skills", "forge", "cauldron", "kiln", "reforge", "report", "shelf", "salvage", "vault", "acre"]
const NOW := DmPbMock.NOW

var _host: Control
var _out := ""
var _scroll := -1


func _ready() -> void:
	theme = DmUi.theme()
	var args := _args()
	var page: String = args.get("page", "")
	_out = args.get("out", "")
	_scroll = int(args.get("scroll", "-1"))
	if args.has("w"):
		get_window().size = Vector2i(int(args["w"]), int(args.get("h", "800")))
	var bg := ColorRect.new()
	bg.color = Color("100c16")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_host = Control.new()
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_host)
	if page == "":
		var bar := HFlowContainer.new()
		bar.position = Vector2(8, 2)
		bar.size = Vector2(1200, 24)
		bar.z_index = 100
		add_child(bar)
		for p in PAGES:
			var b := Button.new()
			b.theme_type_variation = "DmButtonSmall"
			b.text = p.to_upper()
			b.pressed.connect(_show.bind(p))
			bar.add_child(b)
		_show("contracts")
	else:
		_show(page)
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
	for i in 14:
		await get_tree().process_frame
	if _scroll >= 0:
		for w: Node in _host.get_children():
			if w is DmWindow:
				(w as DmWindow).scroll.scroll_vertical = _scroll
		for i in 4:
			await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out)
	print("saved ", _out, " ", img.get_size())
	get_tree().quit()


func _show(page: String) -> void:
	for c in _host.get_children():
		c.queue_free()
	match page:
		"contracts":
			var p := DmContractsPanel.new()
			p.now_override_ms = DmContractsPanel.parse_iso_ms("2026-10-05T00:00:00.000Z") - (3 * 3600000 + 25 * 60000)
			_open(p)
			p.set_board(DmPbMock.contracts_board())
			p.set_counts({"log_oak": 20, "ingot_iron": 1})
		"garden":
			var p := DmGardenPanel.new()
			p.now_override_ms = NOW
			_open(p)
			p.set_bag(DmPbMock.bag())
			p.set_view(DmPbMock.garden_view(NOW))
		"labor":
			var p := DmLaborPanel.new()
			p.now_override_ms = NOW
			_open(p)
			p.set_levels(DmPbMock.levels())
			p.set_view(DmPbMock.labor_view(NOW))
			p.add_loot(0, {"items": [{"itemId": "ore_iron", "name": "Iron Ore", "qty": 38, "rarity": "common"}, {"itemId": "gem_grave_garnet", "name": "Grave Garnet", "qty": 1, "rarity": "rare"}], "totalItems": 39, "gold": 25, "skills": [{"name": "Mining", "xp": 410, "fromLevel": 30, "toLevel": 31}], "milestones": ["1,000 finds, lifetime"], "records": []})
		"skills":
			var p := DmProfessionsPanel.new()
			p.show_contracts = true
			p.show_garden = true
			p.show_labor = true
			p.show_cosmetics = true
			_open(p)
			p.set_skills(DmPbMock.skills())
			p.set_tools(["tool_pickaxe_iron", "tool_hatchet_copper"], ["tool_hatchet_copper"])
			p.set_afk({"active": true, "text": "Mining Iron Seam", "allowed": true})
		"forge", "cauldron", "kiln":
			var f := DmForgePanel.new()
			f.setup("" if page == "forge" else page, page == "forge")
			f.day_key_override = "2026-10-05"
			_host.add_child(f)
			f.open()
			var tab := "mining" if page != "cauldron" else "alchemy"
			f.set_professions([{"profession_id": "mining", "skill_level": 12, "skill_xp": 10}, {"profession_id": "alchemy", "skill_level": 14, "skill_xp": 10}])
			f.set_bag(DmPbMock.bag())
			f.set_recipes(tab, DmRecipes.for_skill(tab))
			f.qty["smelt_copper_ingot"] = 3
			f._render()
			if page == "forge":
				f.set_only_craftable(false)
		"reforge":
			var f := DmForgePanel.new()
			f.setup("", true)
			_host.add_child(f)
			f.open()
			f.select_tab("reforge")
			f.reforge.set_gold(5400)
			f.reforge.set_pieces(DmPbMock.reforge_pieces())
			f.reforge.set_counts({112: 1})
			f.reforge.picked_instance = 112
			f.reforge.confirm = 0
			f.reforge.result_text = "Thralls hit +6.1% harder became Thralls hit +7.4% harder higher · 1,200 gold"
			f.reforge.rebuild()
		"report":
			var p := DmGatherReportPanel.new()
			_open(p)
			p.show_report(DmPbMock.gather_report())
		"shelf":
			var p := DmReagentShelfPanel.new()
			_open(p)
			p.set_found(["herb_nightshade", "ichor_abbess"])
			p.set_held({"herb_mourning_moss": 9, "reagent_grave_dust": 22, "bone_meal": 4})
		"salvage":
			var p := DmSalvagePanel.new()
			var locks := DmItemLocks.new(1)
			var bag := DmPbMock.salvage_bag()
			locks.toggle(bag[4])
			_open(p)
			p.set_locks(locks)
			p.set_skill({"level": 14, "xp": 120, "next": 700})
			p.set_bag(bag)
			p.chosen[0] = true
			p.chosen[1] = true
			p.set_result({"salvaged": [{"item_id": "a"}, {"item_id": "b"}], "gained": [{"item_id": "ingot_gold", "quantity": 4}, {"item_id": "reagent_grave_dust", "quantity": 3}], "xp": 45, "level": 15, "leveledUp": true})
			p.chosen[0] = true
			p.chosen[1] = true
			p.rebuild()
		"vault":
			var p := DmVaultPanel.new()
			var locks := DmItemLocks.new(1)
			var st := DmPbMock.vault_state()
			locks.toggle(st["bag"][1])
			_open(p)
			p.set_locks(locks)
			p.set_state(st)
			p.set_note("Stored Iron Ingot ×2.")
		"acre":
			var a := DmAcreLedger.new()
			_host.add_child(a)
			a.garden.now_override_ms = NOW
			a.labor.now_override_ms = NOW
			a.skills.set_skills(DmPbMock.skills())
			a.skills.set_afk({"active": false, "text": "Idle", "allowed": true})
			a.garden.set_bag(DmPbMock.bag())
			a.garden.set_view(DmPbMock.garden_view(NOW))
			a.labor.set_levels(DmPbMock.levels())
			a.labor.set_view(DmPbMock.labor_view(NOW))
			a.contracts.set_board(DmPbMock.contracts_board())
			a.set_new("garden", true)
			a.open_tab("skills")


func _open(p: DmPanelB) -> void:
	var w := p.make_window()
	_host.add_child(w)
	w.open()
