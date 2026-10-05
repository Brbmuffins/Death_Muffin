class_name DmUiPanelsB
extends RefCounted
## Wiring of the panels_b family: Workbench + stations (Forge, Reforge), Vault, Bone Grinder (Salvage), Reagent Shelf, Gather report, and the Acre ledger's
## tabs (Skills, Garden, Laborers, Contracts). Every signal -> the DmApi call its header documents, then game.refresh_*() (the web's
## inventory-exclusive guard is the `busy` flag of each panel); replies are fed back through the panel's set_*.

var ui: Node
var game: Node
var forges: Dictionary = {}          ## station ("" workbench, kiln, sawpit, fire, cauldron) -> DmForgePanel
var vault: DmVaultPanel
var salvage: DmSalvagePanel
var shelf: DmReagentShelfPanel
var report: DmGatherReportPanel
var professions: DmProfessionsPanel
var garden: DmGardenPanel
var labor: DmLaborPanel
var contracts: DmContractsPanel
var _forge_busy := false
var _bonus_claimed := false


func _init(ui_: Node) -> void:
	ui = ui_
	game = ui_.game
	vault = DmVaultPanel.new()
	_host_window("vault", vault)
	vault.deposit_requested.connect(func(slot: int) -> void: _vault(func() -> DmResult: return await game.api.vault_deposit(cid(), slot)))
	vault.withdraw_requested.connect(func(slot: int) -> void: _vault(func() -> DmResult: return await game.api.vault_withdraw(cid(), slot)))
	vault.deposit_all_requested.connect(func(kind: String, except: Array) -> void: _vault(func() -> DmResult: return await game.api.vault_deposit_all(cid(), kind, except)))
	vault.take_all_requested.connect(_take_all)
	vault.sort_requested.connect(func() -> void: _vault(func() -> DmResult: return await game.api.vault_sort(cid())))
	vault.set_locks(ui.locks)

	salvage = DmSalvagePanel.new()
	_host_window("salvage", salvage)
	salvage.set_locks(ui.locks)
	salvage.salvage_requested.connect(_salvage)

	shelf = DmReagentShelfPanel.new()
	_host_window("shelf", shelf)
	shelf.found_changed.connect(func(ids: Array) -> void: ui.store.set_item("dm_shelf_found_%d" % cid(), JSON.stringify(ids)))

	report = DmGatherReportPanel.new()
	_host_window("report_gather", report)
	report.open_bag_requested.connect(func() -> void:
		report.window.close()
		ui.toggle_panel("inventory"))
	report.close_requested.connect(func() -> void: report.window.close())

	var pa: DmUiPanelsA = ui.pa
	professions = DmProfessionsPanel.new()
	professions.show_contracts = true
	professions.show_garden = true
	professions.show_labor = true
	professions.show_cosmetics = true
	pa.acre_win.add_tab("skills", "Skills", professions, "P")
	garden = DmGardenPanel.new()
	pa.acre_win.add_tab("garden", "Garden", garden, "U")
	labor = DmLaborPanel.new()
	pa.acre_win.add_tab("labor", "Laborers", labor, "H")
	contracts = DmContractsPanel.new()
	pa.acre_win.add_tab("contracts", "Contracts", contracts, "O")
	professions.contracts_pressed.connect(func() -> void: ui.toggle_panel("contracts"))
	professions.garden_pressed.connect(func() -> void: ui.toggle_panel("garden"))
	professions.labor_pressed.connect(func() -> void: ui.toggle_panel("labor"))
	professions.cosmetics_pressed.connect(func() -> void: ui.toggle_panel("cosmetics"))
	professions.start_afk_requested.connect(func(node: String) -> void: ui.call_game_sync("start_afk", [node]))
	professions.pause_afk_requested.connect(func() -> void: ui.call_game_sync("stop_gathering", ["moved"]))
	garden.plant_requested.connect(_plant)
	garden.harvest_requested.connect(_harvest)
	labor.assign_requested.connect(func(slot: int, node: String) -> void: _labor_assign(slot, node))
	labor.recall_requested.connect(func(slot: int) -> void: _labor_assign(slot, ""))
	labor.collect_requested.connect(_labor_collect)
	contracts.deliver_requested.connect(_deliver)
	contracts.refresh_requested.connect(func() -> void: _load_contracts())


func cid() -> int:
	return int(game.character["id"])


func _host_window(id: String, panel: DmPanelB) -> void:
	var w := panel.make_window()
	ui.windows[id] = w
	ui.windows_root.add_child(w)
	w.closed.connect(func() -> void: ui.panel_changed.emit())


func bag_counts() -> Dictionary:
	var out := {}
	for s in game.slots:
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 48:
			out[s["item_id"]] = int(out.get(s["item_id"], 0)) + int(s["quantity"])
	return out


func _bag_rows() -> Array:
	return game.slots.filter(func(s: Dictionary) -> bool: return int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 100)


func _skill_levels() -> Dictionary:
	return ui.skills


func open(p: String) -> void:
	match p:
		"vault":
			vault.set_state({})
			vault.window.open()
			ui.notify("vault_opened")
			var r: DmResult = await game.api.get_vault(cid())
			if r.ok and r.data is Dictionary:
				vault.set_state(r.data)
			else:
				vault.set_error(r.error)
		"salvage":
			_salvage_data()
			salvage.window.open()
			ui.notify("salvage_opened")
		"shelf":
			var found: Variant = DmUiConfig.parse(ui.store.get_item("dm_shelf_found_%d" % cid()))
			shelf.set_found(found if found is Array else [])
			shelf.set_held(bag_counts())
			shelf.window.open()
		"forge":
			open_forge("")


func open_forge(station: String) -> void:
	var key := "" if station in ["", "workbench"] else station
	if key == "alembic":
		key = "cauldron"
	if not forges.has(key):
		var f := DmForgePanel.new()
		f.setup(key, key == "")
		forges[key] = f
		ui.windows["forge" if key == "" else "forge_" + key] = f
		ui.windows_root.add_child(f)
		f.recipes_requested.connect(func(prof: String) -> void: _recipes(f, prof))
		f.craft_requested.connect(func(rid: String, qty: int) -> void: _craft(f, rid, qty))
		f.only_craftable_changed.connect(func(on: bool) -> void: DmAccountPrefs.save_one(game.api, DmAccountPrefs.PREF_ONLY_CRAFTABLE, on))
		if f.reforge != null:
			f.quote_requested.connect(func() -> void: _quote(f))
			f.reforge_requested.connect(func(slot: int, aff: int, cost: int) -> void: _reforge(f, slot, aff, cost))
		f.closed.connect(func() -> void: ui.panel_changed.emit())
	var fp: DmForgePanel = forges[key]
	fp.hold()   # bag + open's own redraws collapse into one rebuild of the recipe rows
	fp.set_bag(_bag_rows())
	if fp.reforge != null:
		fp.reforge.set_pieces(_bag_rows())
		fp.reforge.set_gold(int(game.character.get("gold", 0)))
	fp.open()
	fp.release()
	if station == "cauldron" or station == "alembic":
		ui.notify("cauldron_opened")
	elif station != "" and station != "workbench":
		ui.notify("station_opened")


func _recipes(f: DmForgePanel, prof: String) -> void:
	var r: DmResult = await game.api.get_recipes(prof)
	if r.ok and r.data is Array:
		f.set_recipes("tools" if f.active == "tools" else prof, r.data)
	else:
		f.set_error(r.error)
	var pr: DmResult = await game.api.get_professions(cid())
	f.hold()   # professions + bag: one rebuild, not two
	if pr.ok:
		f.set_professions(pr.data)
	f.set_bag(_bag_rows())
	f.release()


func _craft(f: DmForgePanel, recipe_id: String, qty: int) -> void:
	if _forge_busy:
		return
	_forge_busy = true
	f.set_busy(true, recipe_id, "")
	var err := ""
	var made := 0
	for i in qty:
		var r: DmResult = await game.api.craft(cid(), recipe_id)
		if not r.ok:
			err = r.error if r.error != "" else "Crafting failed."
			break
		made += 1
	f.set_busy(false)
	f.set_error(err)
	await game.refresh_inventory()
	var pr: DmResult = await game.api.get_professions(cid())
	if pr.ok:
		f.set_professions(pr.data)
		for p in pr.data:
			ui.skills[String(p["profession_id"])] = int(p["skill_level"])
	f.set_bag(_bag_rows())
	if made > 0:
		ui.toast("Crafted", "good")
	_forge_busy = false


func _quote(f: DmForgePanel) -> void:
	var r: DmResult = await game.api.reforge_quote(cid())
	if r.ok and r.data is Dictionary:
		f.reforge.set_counts(r.data.get("rerolls", r.data))
	f.reforge.set_pieces(_bag_rows())
	f.reforge.set_gold(int(game.character.get("gold", 0)))


func _reforge(f: DmForgePanel, slot: int, affix: int, cost: int) -> void:
	f.reforge.set_busy(true)
	var r: DmResult = await game.api.reforge_affix(cid(), slot, affix, cost)
	f.reforge.set_busy(false)
	if not r.ok:
		f.reforge.set_error(r.error if r.error != "" else "The Workbench refuses.")
		return
	await game.refresh_inventory()
	game.refresh_character()
	f.reforge.set_pieces(_bag_rows())
	if not (r.data is Dictionary and r.data.has("to") and r.data.has("from")):
		return
	f.reforge.show_result(r.data, "", "")
	ui.play("craft")
	ui.toast("Reforged: %s became %s (%s gold)" % [r.data.get("from"), r.data.get("to"), DmJsFmt.locale(float(r.data.get("cost", 0)))], "good" if int(r.data.get("to", 0)) >= int(r.data.get("from", 0)) else "")
	ui.notify("reforge_done")


# --- vault ------------------------------------------------------------------------------------------------------------------

func _vault(call: Callable) -> void:
	vault.set_busy(true)
	var r: DmResult = await call.call()
	vault.set_busy(false)
	if not r.ok:
		vault.set_error(r.error)
		return
	await game.refresh_inventory()
	if r.data is Dictionary and r.data.has("bag"):
		vault.set_state(r.data)
	else:
		var g: DmResult = await game.api.get_vault(cid())
		if g.ok:
			vault.set_state(g.data)


func _take_all(_kind: String, slots: Array) -> void:
	vault.set_busy(true)
	var note := ""
	for s in slots:
		var r: DmResult = await game.api.vault_withdraw(cid(), int(s))
		if not r.ok:
			note = "Took what fit. %s" % r.error
			break
	vault.set_busy(false)
	await game.refresh_inventory()
	var g: DmResult = await game.api.get_vault(cid())
	if g.ok:
		vault.set_state(g.data)
	if note != "":
		vault.set_note(note)


# --- salvage ----------------------------------------------------------------------------------------------------------------

func _salvage_data() -> void:
	salvage.set_bag(_bag_rows())
	salvage.keep = DmItemText.keeps_for_you(ui.stat_ctx())
	var lvl := int(ui.skills.get("salvaging", 1))
	salvage.set_skill({"level": lvl, "xp": 0, "next": DmGathering.xp_to_next(lvl)})


func _salvage(slots: Array) -> void:
	salvage.set_busy(true)
	var r: DmResult = await game.api.salvage_gear(cid(), slots)
	salvage.set_busy(false)
	if not r.ok:
		salvage.set_error(r.error if r.error != "" else "Salvage failed")
		return
	await game.refresh_inventory()
	salvage.set_bag(_bag_rows())
	salvage.set_result(r.data)
	ui.on_salvaged(r.data)


# --- acre ledger ----------------------------------------------------------------------------------------------------------------

func on_acre_open(p: String) -> void:
	match p:
		"professions":
			_professions_data()
		"garden":
			garden.set_bag(_bag_rows())
			var r: DmResult = await game.api.get_garden(cid())
			if r.ok and r.data is Dictionary and not r.data.is_empty():
				garden.set_view(r.data)
		"labor":
			labor.set_levels(ui.skills)
			var r2: DmResult = await game.api.get_labor(cid())
			if r2.ok and r2.data is Dictionary and r2.data.has("slots"):
				labor.set_view(r2.data)
				ui.labor_summary = DmGuidance.summarize_labor(r2.data)
		"contracts":
			_load_contracts()


func _professions_data() -> void:
	professions.hold()   # skills + tools + afk are one redraw, not three
	if professions.skills.is_empty():
		var sk := {}
		for k in ui.skills:
			sk[k] = {"level": int(ui.skills[k]), "xp": 0}
		professions.set_skills(sk)   # first look only: later opens keep the last server numbers until the reply lands
	var held: Array = []
	var belt: Array = []
	for s in game.slots:
		if DmGathering.is_belt_slot(int(s["slot_index"])):
			belt.append(s["item_id"])
		elif int(s["slot_index"]) < 48:
			held.append(s["item_id"])
	professions.set_tools(held, belt)
	var st: Variant = ui.call_game_sync("afk_status")
	professions.set_afk(st if st is Dictionary else {}, "")
	professions.release()
	var r: DmResult = await game.api.get_professions(cid())
	if r.ok:
		var m := {}
		for p in r.data:
			m[String(p["profession_id"])] = {"level": int(p["skill_level"]), "xp": int(p["skill_xp"])}
			ui.skills[String(p["profession_id"])] = int(p["skill_level"])
		professions.set_skills(m)


func _load_contracts() -> void:
	contracts.set_counts(bag_counts())
	var r: DmResult = await game.api.get_contracts(cid())
	if r.ok and r.data is Dictionary and r.data.has("contracts"):
		contracts.set_board(r.data)
		ui.contract_summary = DmGuidance.summarize_contracts(r.data)


func _deliver(slot: int) -> void:
	contracts.set_busy(true)
	var r: DmResult = await game.api.deliver_contract(cid(), slot)
	contracts.set_busy(false)
	if not r.ok:
		contracts.set_error(r.error)
		return
	await game.refresh_inventory()
	game.refresh_character()
	contracts.set_counts(bag_counts())
	contracts.set_board(r.data)
	ui.contract_summary = DmGuidance.summarize_contracts(r.data)
	ui.play("orderFilled")
	ui.toast("Order filled", "good")


func _plant(plot: String, seed_id: String, compost: bool) -> void:
	garden.set_busy(true)
	var r: DmResult = await game.api.plant_garden(cid(), plot, seed_id, compost)
	garden.set_busy(false)
	if r.ok:
		await game.refresh_inventory()
		garden.set_bag(_bag_rows())
		garden.set_view(r.data)
		ui.play("gardenPlant")
	else:
		garden.set_view(garden.view)


func _harvest(plot: String) -> void:
	garden.set_busy(true)
	var r: DmResult = await game.api.harvest_garden(cid(), plot)
	garden.set_busy(false)
	if r.ok:
		await game.refresh_inventory()
		garden.set_bag(_bag_rows())
		garden.set_view(r.data)
		ui.play("gardenHarvest")


func _labor_assign(slot: int, node: String) -> void:
	labor.set_busy(true)
	var r: DmResult = await game.api.assign_labor(cid(), slot, node)
	labor.set_busy(false)
	if r.ok:
		labor.set_view(r.data)


func _labor_collect(slot: int) -> void:
	labor.set_busy(true)
	var r: DmResult = await game.api.collect_labor(cid(), slot)
	labor.set_busy(false)
	if r.ok:
		await game.refresh_inventory()
		game.refresh_character()
		labor.set_view(r.data)
		var c: Variant = r.data.get("collected") if r.data is Dictionary else null
		if c is Dictionary:
			ui.play("coin")


func refresh_open() -> void:
	if vault.window != null and vault.window.visible:
		pass
	if salvage.window != null and salvage.window.visible:
		salvage.set_bag(_bag_rows())
	for f in forges.values():
		if f.visible:
			f.set_bag(_bag_rows())
	if shelf.window != null and shelf.window.visible:
		shelf.set_held(bag_counts())
