class_name DmUiPanelsA
extends RefCounted
## Wiring of the panels_a family (Character sheet, Capes & Pets, Grimoire + Legion, Atlas, Codex, Altar of Ascension, Waystones, Change class) and the
## three merged windows (WorldScene acreWin / charWin / grimWin). Signals -> DmApi calls (each panel header documents them), then game.refresh_*().

var ui: Node
var game: Node
var acre_win: DmPaTabbedWindow
var char_win: DmCharacterWindow
var grim_win: DmGrimoireWindow
var codex: DmCodexPanel
var atlas: DmAtlasPanel
var ascension: DmAscensionPanel
var waystone: DmWaystonePanel
var class_panel: DmClassPanel
var loadouts: DmLoadoutPresets
var grim_select: Variant = null
var _legion_busy := false


func _init(ui_: Node) -> void:
	ui = ui_
	game = ui_.game
	acre_win = DmPaTabbedWindow.new()
	acre_win.title = "Acre ledger"
	acre_win.panel_width = 860
	char_win = DmCharacterWindow.new()
	grim_win = DmGrimoireWindow.new()
	grim_win.set_family(ui.family())
	for w in [acre_win, char_win, grim_win]:
		ui.windows_root.add_child(w)
		w.closed.connect(func() -> void: ui.panel_changed.emit())
	acre_win.tab_changed.connect(func(id: String) -> void: _on_tab("acre", id))
	char_win.tab_changed.connect(func(id: String) -> void: _on_tab("sheet", id))
	grim_win.tab_changed.connect(func(id: String) -> void: _on_tab("grim", id))

	char_win.cosmetics.cape_toggled.connect(func(id: String) -> void:
		_cosmetics_act({"cape": null if char_win.cosmetics.view.get("selected", {}).get("cape") == id or id == "" else id}))
	char_win.cosmetics.pet_toggled.connect(func(id: String) -> void:
		_cosmetics_act({"pet": null if char_win.cosmetics.view.get("selected", {}).get("pet") == id or id == "" else id}))
	char_win.cosmetics.adopt_requested.connect(_adopt)

	var gv: DmGrimoireView = grim_win.grimoire
	gv.assign_requested.connect(func(slot: int, id: String) -> void: ui.set_rite(slot, id))
	gv.assign_primary_requested.connect(func(id: String) -> void: ui.set_primary(id))
	gv.mark_seen.connect(func(ids: Array) -> void:
		if ui.warming:
			return
		ui.rites.mark_seen(ids)
		grimoire_changed())
	gv.rune_socket_requested.connect(func(rite: String, rune_id: String) -> void:
		var err: String = await ui.inv.socket_rune_id(rite, rune_id)
		gv.rune_done(err if err != "" else null)
		refresh_grimoire())
	if ui.is_necromancer():
		loadouts = DmLoadoutPresets.new()
		loadouts.setup(ui)
		gv.loadout_host.add_child(loadouts)
	else:
		loadouts = DmLoadoutPresets.new()
		loadouts.setup(ui)

	var lv: DmLegionView = grim_win.legion
	lv.take_off_requested.connect(func(kit_id: String) -> void:
		var err: Variant = await ui.inv.take_off_legion(kit_id)
		_legion_result(err))
	lv.give_requested.connect(func(slot: int) -> void:
		var err: Variant = await ui.inv.give_spare(slot)
		_legion_result(err))
	lv.reinforce_requested.connect(_reinforce)

	codex = DmCodexPanel.new()
	ui._add_window("codex", codex)
	codex.atlas_requested.connect(func() -> void: ui.toggle_panel("atlas"))
	codex.chronicle_requested.connect(_load_chronicle)
	atlas = DmAtlasPanel.new()
	ui._add_window("atlas", atlas)
	ascension = DmAscensionPanel.new()
	ui._add_window("ascension", ascension)
	ascension.vows_swear_requested.connect(_swear)
	ascension.ascend_confirmed.connect(_ascend)
	ascension.boon_buy_requested.connect(_boon)
	ascension.unlock_requested.connect(_unlock)
	waystone = DmWaystonePanel.new()
	ui._add_window("map", waystone)
	waystone.travel_requested.connect(func(id: String) -> void: ui.call_game_sync("travel", [id]))
	class_panel = DmClassPanel.new()
	ui._add_window("class", class_panel)
	class_panel.class_chosen.connect(_change_class)


func _on_tab(win: String, id: String) -> void:
	var wk := "sheet" if win == "sheet" else win
	ui.use_tab_cue("sheet" if win == "sheet" else win, id)
	var w: DmWindow = acre_win if win == "acre" else (char_win if win == "sheet" else grim_win)
	if w.visible:
		on_open(_panel_of(win, id))


func _panel_of(win: String, tab: String) -> String:
	if win == "acre":
		return {"skills": "professions"}.get(tab, tab)
	if win == "sheet":
		return {"stats": "sheet", "pets": "cosmetics"}[tab]
	return tab


func cid() -> int:
	return int(game.character["id"])


func gold() -> int:
	return int(game.character.get("gold", 0))


## Opens the data of a panel key (after its window is shown or its tab selected).
func on_open(p: String) -> void:
	match p:
		"sheet":
			render_sheet()
			ui.notify("stat_sheet_opened")
		"cosmetics":
			_load_cosmetics()
		"grimoire":
			grim_win.grimoire.open_session(grim_select)
			refresh_grimoire()
			if loadouts != null and ui.is_necromancer():
				loadouts.load_rows()
		"legion":
			render_legion()
		"professions", "garden", "labor", "contracts":
			ui.pb.on_acre_open(p)


func open_window(p: String) -> void:
	match p:
		"codex":
			_codex_data()
			codex.open()
		"atlas":
			_atlas_data()
			atlas.open_atlas()
		"ascension":
			ascension.set_state(_ascension_state())
			ascension.open_altar()
		"map":
			waystone.set_unlocked(_waystones())
			waystone.open()
		"class":
			class_panel.set_data(int(game.character["class_index"]))
			class_panel.open()


func refresh_open() -> void:
	if char_win.visible and char_win.active == "stats":
		render_sheet()
	if grim_win.visible:
		if grim_win.active == "legion":
			render_legion()
		else:
			refresh_grimoire()
	if char_win.visible and char_win.active == "pets":
		char_win.cosmetics.set_charm_counts(_charms())
	if ascension.visible:
		ascension.set_state(_ascension_state())
	if atlas.visible:
		_atlas_data()
	if ui.inv.panel.visible:
		pass
	ui.pb.refresh_open()


func process(delta: float) -> void:
	tick(delta)


# --- sheet / cosmetics -------------------------------------------------------------------------------------------------

func render_sheet() -> void:
	var d := DmGearStats.sheet_data(ui.stat_ctx())
	char_win.sheet.set_data(d)


func _charms() -> Dictionary:
	var out := {}
	for s in game.slots:
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 48:
			out[s["item_id"]] = int(out.get(s["item_id"], 0)) + int(s["quantity"])
	return out


func _load_cosmetics() -> void:
	char_win.cosmetics.set_charm_counts(_charms())
	var r: DmResult = await game.api.get_cosmetics(cid())
	if r.ok and r.data is Dictionary and r.data.has("capes"):
		char_win.cosmetics.set_view(r.data)
	else:
		char_win.cosmetics.set_error(r.error if r.error != "" else "Could not reach the Sexton.")


func _cosmetics_act(patch: Dictionary) -> void:
	char_win.cosmetics.set_busy(true)
	var r: DmResult = await game.api.select_cosmetics(cid(), patch)
	char_win.cosmetics.set_busy(false)
	if r.ok:
		char_win.cosmetics.set_view(r.data)
		game.refresh_character()
	else:
		char_win.cosmetics.set_error(r.error if r.error != "" else "The Sexton refuses.")


func _adopt(pet_id: String) -> void:
	char_win.cosmetics.set_busy(true)
	var r: DmResult = await game.api.adopt_pet(cid(), pet_id)
	char_win.cosmetics.set_busy(false)
	if r.ok:
		await game.refresh_inventory()
		if r.data is Dictionary:
			char_win.cosmetics.set_view(r.data)
	else:
		char_win.cosmetics.set_error(r.error if r.error != "" else "The Sexton refuses.")


# --- grimoire / legion ---------------------------------------------------------------------------------------------------

func refresh_grimoire() -> void:
	var gv: DmGrimoireView = grim_win.grimoire
	var lvl: float = ui._rite_level()
	# Runes first without a redraw, so the grimoire is drawn once (it was drawn twice per open/refresh).
	if ui.is_necromancer():
		gv.set_runes({"sockets": DmRunes.sockets_of(game.slots), "owned": DmRunes.owned_runes(game.slots)}, false)
	gv.set_state({"rites": {"primary": ui.rites.primary, "keys": ui.rites.keys}, "level": lvl, "unseen": ui.rites.unseen(), "kit": ui.kit()})


func grimoire_changed() -> void:
	if grim_win.visible and grim_win.active == "grimoire":
		refresh_grimoire()


func render_legion() -> void:
	var b: Dictionary = ui.build()
	var thrall: Variant = {"hp": float(b["stats"]["thrallHp"]), "damage": float(b["stats"]["thrallDamage"])}
	grim_win.legion.set_data(DmLegionText.view_data(game.slots, int(game.progress.get("legionTier", 0)), gold(), thrall, Callable(DmUiInventory, "icon_of_row")))


func _legion_result(err: Variant) -> void:
	if err != null:
		grim_win.legion.set_error(String(err))
	else:
		render_legion()


func _reinforce() -> void:
	var r: DmResult = await game.api.necro_purchase(cid(), "legion")
	if not r.ok:
		grim_win.legion.set_error("Not enough gold." if r.error == "" else r.error)
		return
	ui.play("buy")
	await game.refresh_progress()
	game.refresh_character()
	ui.toast("The legion is bound tighter: tier %d" % int(game.progress.get("legionTier", 0)), "good")
	render_legion()


# --- atlas / codex ---------------------------------------------------------------------------------------------------------

var _atlas_key := 0
var _atlas_inputs: Dictionary = {}
var _atlas_task := -1                 # WorkerThreadPool task recomputing the verdicts for _atlas_task_key
var _atlas_task_key := 0
var _atlas_task_out: Dictionary = {}  # written by the worker, read only after the task completed
var _atlas_stale_t := -1.0            # seconds until the verdicts are recomputed in the background (-1 = up to date / not wanted yet)
const ATLAS_SETTLE_S := 0.8           # looting changes the bag every second: recompute once it goes quiet


## What the verdicts depend on (see DmStatKey) plus which catalogue pieces are worn.
func _atlas_verdict_key(ctx: Dictionary, owned: Dictionary) -> int:
	var worn: Array = []
	for id in owned:
		if bool(owned[id].get("worn", false)):
			worn.append(id)
	worn.sort()
	return [DmStatKey.of(ctx), worn].hash()


func _atlas_data() -> void:
	var ctx: Variant = ui.stat_ctx()
	var owned := DmAtlasPanel.owned_from_slots(game.slots)
	var inputs := {"verdicts": {}, "outlooks": {}}
	if ctx != null:
		# A verdict for every atlas item is ~0.3 s: reuse it until the stat sources or the gear change (a worker thread may already have it).
		var key := _atlas_verdict_key(ctx, owned)
		if key != _atlas_key or _atlas_inputs.is_empty():
			if _atlas_task >= 0 and _atlas_task_key == key:
				WorkerThreadPool.wait_for_task_completion(_atlas_task)
				_atlas_task = -1
				_atlas_inputs = _atlas_task_out
			else:
				_atlas_wait()
				_atlas_inputs = DmAtlasGear.panel_inputs(ctx, DmPaData.atlas().get("items", {}).keys(), owned)
			_atlas_key = key
		_atlas_stale_t = -1.0
		inputs = _atlas_inputs
	atlas.set_context({"disc": String(ui.build()["discipline"]["id"]), "level": int(game.character.get("level", 1)), "area": String(game.area_id), "owned": owned,
		"verdicts": inputs["verdicts"], "outlooks": inputs["outlooks"]})


## The UI is going away (area change, quit): never leave the worker running into a freed object or the engine's shutdown.
func shutdown() -> void:
	_atlas_wait()
	_atlas_stale_t = -1.0


func _atlas_wait() -> void:
	if _atlas_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_atlas_task)
		_atlas_task = -1


## The bag or the character changed: have the verdicts recomputed on a worker thread once things settle, so opening the Atlas finds them done.
## Only after the first (main-thread) computation: that one fills every lazily built static table the worker then only reads.
func atlas_dirty() -> void:
	if not _atlas_inputs.is_empty():
		_atlas_stale_t = ATLAS_SETTLE_S


## True when no verdict recompute is pending or running (tests/perf wait for it after changing the bag).
func atlas_idle() -> bool:
	return _atlas_stale_t < 0.0 and (_atlas_task < 0 or WorkerThreadPool.is_task_completed(_atlas_task))


func tick(delta: float) -> void:
	if _atlas_stale_t < 0.0:
		return
	_atlas_stale_t -= delta
	if _atlas_stale_t > 0.0:
		return
	_atlas_stale_t = -1.0
	var ctx: Variant = ui.stat_ctx()
	if ctx == null or _atlas_task >= 0 and not WorkerThreadPool.is_task_completed(_atlas_task):
		_atlas_stale_t = ATLAS_SETTLE_S
		return
	var owned := DmAtlasPanel.owned_from_slots(game.slots)
	var key := _atlas_verdict_key(ctx, owned)
	if key == _atlas_key:
		return
	if _atlas_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_atlas_task)
		_atlas_task = -1
	var snap: Dictionary = (ctx as Dictionary).duplicate(true)
	_atlas_task_key = key
	_atlas_task_out = {}
	var ids: Array = DmPaData.atlas().get("items", {}).keys()
	_atlas_task = WorkerThreadPool.add_task(func() -> void: _atlas_task_out = DmAtlasGear.panel_inputs(snap, ids, owned), false, "atlas verdicts")


func _codex_data() -> void:
	codex.set_discipline(String(ui.build()["discipline"]["id"]))
	codex.auto_combat_allowed = bool(game.character.get("auto_combat_allowed", false))
	codex.set_journal(ui.codex_journal["dead"].keys(), ui.codex_journal["area"].keys())
	codex.set_runes_found(ui.runes_found())
	codex.set_met_npcs(ui.memory.met_npcs)


func _load_chronicle() -> void:
	if game.has_method("flush_chronicle"):
		await game.flush_chronicle()   # the panel shows the saved record: send what is pending first
	var r: DmResult = await game.api.get_chronicle(cid())
	if r.ok and r.data is Dictionary:
		var c := DmChronicle.new()
		c.set_data(r.data)
		codex.set_chronicle(c.view())


# --- ascension (src/ui/AscensionPanel.ts callbacks in WorldScene: doAscend / doSwear / doOpen / buyBoon) -------------------------

func _ascension_state() -> Dictionary:
	var l: Dictionary = game.progress.duplicate(true)
	l["shards"] = int(l.get("shards", 0))
	return l


func _after_necro(r: DmResult) -> void:
	await game.refresh_progress()
	game.refresh_character()
	ascension.set_state(_ascension_state())


func _ascend() -> void:
	var heat := DmAscension.vow_heat(game.progress.get("vows", {}))
	var r: DmResult = await game.api.necro_ascend(cid())
	if not r.ok:
		ui.toast(r.error if r.error != "" else "The Altar refuses.", "err")
		return
	ui.play("levelUp")
	var earned := int((r.data as Dictionary).get("earned", 0)) if r.data is Dictionary else 0
	await _after_necro(r)
	ui.hud.banner("Ascended at heat %d" % heat, "+%d Ashes · swear your vows for the next run" % earned, 4200)


func _swear(vows: Dictionary) -> void:
	var r: DmResult = await game.api.necro_vows(cid(), vows)
	if not r.ok:
		ui.toast(r.error if r.error != "" else "The Altar refuses.", "err")
		return
	ui.play("shard")
	await _after_necro(r)
	ui.toast("Vows sworn: heat %d" % DmAscension.vow_heat(game.progress.get("vows", {})), "good")


func _boon(id: String) -> void:
	var r: DmResult = await game.api.necro_boon(cid(), id)
	if not r.ok:
		ui.toast(r.error if r.error != "" else "The Altar refuses.", "err")
		return
	ui.play("shard")
	await _after_necro(r)
	var b: Dictionary = DmProgContent.get_data().get("boons", {}).get(id, {})
	ui.toast("%s — %s" % [b.get("name", id), b.get("blurb", "")], "good")


func _unlock(key: String) -> void:
	var r: DmResult = await game.api.necro_unlock(cid(), key)
	if not r.ok:
		ui.toast(r.error if r.error != "" else "The Altar refuses.", "err")
		return
	ui.play("levelUp")
	await _after_necro(r)
	ui.toast("%s unlocked" % key.substr(key.find(":") + 1), "good")


# --- waystones / class ------------------------------------------------------------------------------------------------------

func _waystones() -> Array:
	var out: Array = []
	var unlocked: Array = game.progress.get("unlocked", [])
	for a in DmContent.area_order():
		if not bool(DmContent.area(String(a)).get("instance", false)) and unlocked.has(a):
			out.append(a)
	return out


func _change_class(index: int) -> void:
	if index == int(game.character["class_index"]):
		class_panel.close()
		return
	class_panel.begin_saving()
	var r: DmResult = await game.api.change_discipline(cid(), index)
	if not r.ok:
		class_panel.fail(r.error if r.error != "" else "The class would not change.")
		return
	class_panel.finish()
	if r.data is Dictionary and r.data.has("id"):
		game.character = r.data
	ui.call_game_sync("class_changed", [game.character])
	game.refresh_character()
