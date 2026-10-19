extends SceneTree
## DmGameUi against the mock DmGame (no live server):  godot --headless --path client --script res://tests/game_ui/run.gd

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
	ui._hud_at -= DmGameUi.HUD_INTERVAL_MS + 20   # the HUD interval has elapsed (backdated: no wall-clock wait)
	await _frames(2)
	_check(ui.hud.vm["hp"] == 123, "hud follows game within HUD_INTERVAL_MS (the web's 50 ms HUD cadence)")

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
	var vault_win := ui.window_for("vault")
	_check(ui.point_in_window(vault_win.get_global_rect().get_center()), "a point inside an open window counts as on the window")
	ui.close_panels()
	await _frames(2)
	_check(not ui.point_in_window(vault_win.get_global_rect().get_center()), "a closed window no longer blocks world clicks")
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
	_check(not game.calls_to("/api/inventory/sell").is_empty() and game.calls_to("/api/inventory/save").is_empty(), "sell is the server's sale, never a bag save")
	_check(int(game.character["gold"]) == 1502, "sell credits gold")
	# Selling gear in combat must not re-text every other card (each verdict is a gear-power simulation): the cards and the junk verdicts
	# depend on what is worn, never on the other bag rows, and the server's copy of an unchanged row (new id, floats) is the same card.
	var gear_cards: Array = []
	for c in ui.inv.panel.bag:
		if not c.is_empty() and c.has("verdict") and not c["locked"]:
			gear_cards.append(c)
	_check(gear_cards.size() >= 2, "two bag gear cards to sell one of")
	if gear_cards.size() >= 2:
		var keep_id := String(gear_cards[1]["item_id"])
		var verdict0: Dictionary = _card(ui, keep_id)["verdict"]
		ui.inv.panel.sell_requested.emit(gear_cards[0], 1)
		await _frames(3)
		_check(is_same(_card(ui, keep_id)["verdict"], verdict0), "selling gear keeps the other cards (no re-text)")
		var server_copy: Array = []
		for s in game.slots:
			var r: Dictionary = s.duplicate(true)
			r["id"] = int(r.get("id", 0)) + 1000
			r["slot_index"] = float(r["slot_index"])
			server_copy.append(r)
		game.slots = server_copy
		game.inventory_changed.emit()
		await _frames(2)
		var after := _card(ui, keep_id)
		_check(is_same(after["verdict"], verdict0) and int(after["row"]["id"]) >= 1000, "the server's copy of a row reuses its card with the new row")
	game.clear_calls()
	ui.inv.panel.sort_requested.emit()
	await _frames(3)
	_check(not game.calls_to("/api/inventory/sort").is_empty() and game.calls_to("/api/inventory/save").is_empty(), "sort is the server's, never a bag save")

	await _more(game, ui)
	await _panels(game, ui)
	await _extras(game, ui)
	await _card_rows()
	print("%d passed, %d failed" % [_pass, _fail])
	print("%s game_ui %d checks%s" % ["PASS" if _fail == 0 else "FAIL", _pass + _fail, "" if _fail == 0 else " (%d failed)" % _fail])
	quit(1 if _fail > 0 else 0)


func _more(game: DmMockGame, ui: DmGameUi) -> void:
	ui.close_panels()
	# --- Settings -> game.apply_settings, tips wiring ---
	ui.toggle_panel("settings")
	await _frames(3)
	var sp: DmSettingsPanel = ui.set_ui.panel
	sp.changed.emit("graphics", "low")
	_check(game.applied_settings.size() >= 1 and game.settings["graphics"] == "low", "settings change -> apply_settings")
	sp.changed.emit("no_tips", true)
	_check(not ui.counsel.tips_enabled and game.settings["no_tips"] == true, "no_tips turns the counsel off")
	sp.changed.emit("no_tips", false)
	_check(ui.counsel.tips_enabled, "no_tips off re-enables the counsel")
	sp.action.emit("reset_tips")
	ui.counsel.tips_disabled.emit()
	_check(game.settings["no_tips"] == true, "counsel 'Don't show tips' stores no_tips")
	ui.update_setting({"no_tips": false})
	ui.update_setting({"hud_scale": 0.75})
	_check(is_equal_approx(ui.hud.hud_scale, 0.75) and is_equal_approx(ui.game.applied_settings.back()["hud_scale"], 0.75), "HUD size setting reaches the HUD and the game")
	ui.update_setting({"hud_scale": 9.0})
	_check(is_equal_approx(ui.hud.hud_scale, 1.3), "HUD size is clamped")
	_check(sp.find_children("*", "OptionButton", true, false).size() >= 1 and sp.values.has("hud_scale"), "Settings panel carries HUD size")
	ui.update_setting({"hud_scale": 1.0})
	sp.action.emit("bug_report")
	await _frames(3)
	_check(not sp.strip_slot.visible, "the tab strip is hidden while the bug report fills the Settings body")
	_check(ui.is_open("settings") and ui.set_ui.bug_report_open() and ui.set_ui.report.is_visible_in_tree(), "bug report renders inside the Settings body")
	ui.set_ui.report.message.text = "the thralls stopped following me after travel"
	ui.set_ui.report._sync()
	game.clear_calls()
	await ui.set_ui.report.send()
	var br := game.calls_to("/api/bug-reports")
	_check(br.size() == 1 and br[0]["body"]["category"] == "bug" and br[0]["body"]["characterId"] == 7, "bug report sent via DmApi")
	_check(ui.set_ui.report.attach_log.button_pressed, "Attach my game log is ticked by default")
	var ld := "user://test_bug_logs"
	DirAccess.make_dir_recursive_absolute(ld)
	var fa := FileAccess.open(ld.path_join("godot2026-10-08T21.15.00.log"), FileAccess.WRITE)
	fa.store_string("boot\nSCRIPT ERROR: Invalid access in tooltip\npassword=hunter2 Authorization: Bearer abc.def\nCrashHandlerException: Program crashed with signal 11\n")
	fa.close()
	fa = FileAccess.open(ld.path_join("godot.log"), FileAccess.WRITE)
	fa.store_string("this session: tokens loaded\n")
	fa.close()
	var lt := DmBugReportView.game_log_tail(11000, ld)
	_check(lt.contains("=== previous session (godot2026-10-08T21.15.00.log) ===") and lt.contains("CrashHandlerException") and lt.find("previous session") < lt.find("this session"), "game log: crashed session first, this one last")
	_check(not lt.contains("hunter2") and not lt.contains("abc.def") and lt.contains("tokens loaded"), "game log: passwords and bearer tokens blanked, ordinary words kept")
	_check(DmBugReportView.log_errors(lt).size() == 2 and DmBugReportView.game_log_tail(40, ld).length() <= 40, "game log: error lines picked out, size capped")
	_check(DmBugReportView.game_log_tail(11000, "user://no_such_logs") == "", "game log: no log folder, nothing attached")
	# automatic crash reports (DmCrashWatch): a lock left by a run that never shut down becomes a pending report of that run's log
	var prev_only := DmBugReportView.game_log_tail(11000, ld, true)
	_check(prev_only.contains("crashed session") and prev_only.contains("CrashHandlerException") and not prev_only.contains("tokens loaded") and not prev_only.contains("hunter2"), "crash log: only the crashed session, scrubbed")
	var lk := "user://test_session.lock"; var pd := "user://test_crash_pending.json"
	DmCrashWatch.end(lk); DmCrashWatch.clear(pd)
	_check(not DmCrashWatch.begin("dev", lk, pd, ld) and not FileAccess.file_exists(lk), "crash watch: a dev build writes no lock")
	var rel := "20261015.030804-d1e8b44"
	_check(not DmCrashWatch.begin(rel, lk, pd, ld) and FileAccess.file_exists(lk), "crash watch: a first start is not a crash, and writes the lock")
	DmCrashWatch.end(lk)
	_check(not DmCrashWatch.begin(rel, lk, pd, ld), "crash watch: after a normal shutdown, no crash")
	_check(DmCrashWatch.begin(rel, lk, pd, ld) and FileAccess.file_exists(pd), "crash watch: a lock left behind = the last run crashed, report pending")
	var crep := DmCrashWatch.pending_report(7, pd)
	_check(crep["category"] == "bug" and crep["characterId"] == 7 and String(crep["message"]).begins_with("Automatic crash report") and String(crep["message"]).contains(rel), "crash report: says it is automatic and names the build")
	_check(crep["context"]["crash"] == true and String(crep["context"]["log"]).contains("CrashHandlerException") and (crep["context"]["errors"] as Array).size() >= 1, "crash report: carries the crashed log and its errors")
	DmCrashWatch.clear(pd)
	_check(DmCrashWatch.pending_report(7, pd).is_empty(), "crash report: cleared once sent")
	DmCrashWatch.end(lk)
	for f in DirAccess.get_files_at(ld):
		DirAccess.remove_absolute(ld.path_join(f))
	DirAccess.remove_absolute(ld)
	ui.set_ui.report.back_pressed.emit()
	await _frames(3)
	_check(ui.is_open("settings") and not ui.set_ui.bug_report_open() and ui.set_ui.panel.body.get_child_count() > 3, "Back restores the Settings body")
	_check(ui.set_ui.panel.strip_slot.visible, "Back brings the tab strip back")
	ui.set_ui.panel.action.emit("party_window")
	await _frames(3)
	_check(ui.is_open("party") and not ui.is_open("settings"), "Settings' Open the Party tab button opens the Social window on Party")
	ui.open_bug_report()
	await _frames(3)
	_check(ui.set_ui.bug_report_open(), "the HUD's Report a bug button opens it in Settings too")
	ui.close_panels()
	# difficulty rule
	game.character["auto_combat_allowed"] = true
	ui.update_setting({"difficulty": "easy"})
	_check(game.settings["auto_combat"] == true, "easy turns auto combat on for the allowed")
	ui.update_setting({"difficulty": "hard"})
	_check(game.settings["auto_combat"] == false, "hard turns it off")
	game.character["auto_combat_allowed"] = false

	# --- game events: toast / banner / loot / chat / tips ---
	game.game_event.emit("toast", {"text": "Level 31 reached", "kind": "good"})
	game.game_event.emit("banner", {"title": "The Graves", "sub": "", "ms": 1000})
	game.game_event.emit("loot", {"name": "Bone Dust", "qty": 3, "rarity": "common"})
	game.game_event.emit("chat", {"text": "hello"})
	_check(ui._chat_ping_player == null, "a chat line without a ping flag is silent")
	game.game_event.emit("chat", {"text": "[Ann] hi", "ping": true})
	_check(ui._chat_ping_player != null and ui._chat_ping_player.stream != null and ui._chat_ping_player.playing, "another player's chat line plays the ping")
	await _frames(2)
	_check(ui.hud.toasts.get_child_count() >= 1, "toast event shows a toast")
	_check(ui.hud.banner_active(), "banner event shows a banner")
	var shown: Array = []
	ui.counsel.card_shown.connect(func(id: String, _k: String, _t: String, _b: String, _ms: int) -> void: shown.append(id))
	ui.close_panels()
	game.game_event.emit("world_entered", {"family": "necromancer", "level": 12, "grimoire_unlocked": true})
	for i in 40:
		ui.counsel.tick(0.25, DmCounselCadence.not_busy())
	_check(shown.size() > 0, "game_event counsel id shows a card (%s)" % str(shown))

	# --- Next box ---
	ui._guide_t = 0.0
	await _frames(2)
	_check(ui.guidance_hud.current != null and ui.hud.vm.get("next") != null, "Next box fed by guidance")
	var before := String(ui.hud.vm.get("next"))
	var top_id := String(ui.guidance_hud.current["id"])
	ui.hud.dismiss_next.emit()
	await _frames(2)
	_check(ui.guidance_hud.dismissed == top_id and (ui.guidance_hud.current == null or String(ui.guidance_hud.current["id"]) != top_id), "dismiss_next drops that suggestion")
	_check(before != "", "next text was shown")

	# --- dialogue ---
	game.npc_interact.emit("prior")
	await _frames(2)
	_check(ui.dialogue.visible and ui.dialogue.lines.size() > 0, "npc_interact opens the dialogue")
	ui.dialogue.close()

	# --- HUD intents ---
	ui.hud.cast.emit(2)
	ui.hud.buy_damage.emit()
	ui.hud.buy_wave.emit()
	_check(game.casts == [2, "buy:damage", "buy:wave"], "hud cast/buy -> game")
	ui.hud.open_panel.emit("codex")
	await _frames(3)
	_check(ui.is_open("codex"), "menu button opens codex")
	ui.close_panels()
	ui.hud.swap_slot.emit(2)
	await _frames(3)
	_check(ui.is_open("grimoire"), "swap key cap opens the grimoire")
	ui.close_panels()
	for want_open in [true, false]:
		# the click is the button's `pressed` signal: a built-in Button's `_gui_input` cannot be called from a script, and the headless window (64 x 64) holds no
		# pixel of the HUD for a pushed mouse event (the old game's version of this loop called `_gui_input`, errored there and skipped the rest of this function
		# without a failed check)
		ui.hud.grim_btn.pressed.emit()
		await _frames(3)
		_check(ui.is_open("grimoire") == want_open, "Spells button click %s the grimoire" % ("opens" if want_open else "closes"))
	ui.close_panels()

	# --- belt picker + drag drop ---
	ui.belt_picker.open("elixir")
	_check(ui.belt_picker.rows.size() == 1 and ui.belt_picker.rows[0]["id"] == "elixir_moonlight", "belt picker lists the bag's elixirs")
	ui.belt_picker.close()
	ui.hud.brew_dropped.emit("elixir", "elixir_moonlight")
	_check(DmUiConfig.parse(ui.store.get_item(ui.belt_key())).get("elixir") == "elixir_moonlight", "brew drop sets the belt")
	var chip := DmHudBrewChip.new()
	chip.slot = "tonic"
	_check(chip._can_drop_data(Vector2.ZERO, {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "tonic_graveluck"}) and not chip._can_drop_data(Vector2.ZERO, {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "elixir_moonlight"}), "brew chip takes only its own slot's brew")
	_check(not chip._can_drop_data(Vector2.ZERO, {"type": "other"}), "brew chip accepts only belt drags")
	chip.slot = "heal"
	_check(not chip._can_drop_data(Vector2.ZERO, {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "x"}), "heal slot refuses a non-flask")
	_check(chip._can_drop_data(Vector2.ZERO, {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "flask_hp_minor"}), "heal slot takes a healing flask")
	ui.hud.brew_dropped.emit("heal", "flask_hp_grand")
	_check(DmUiConfig.parse(ui.store.get_item(ui.belt_key())).get("heal") == "flask_hp_grand" and ui.belt_pick()["heal"] == "flask_hp_grand", "flask drop sets the heal slot")
	var rp := ui.inv.panel
	var heal_cell: DmItemSlot = rp._potion_slots["heal"]
	_check(heal_cell._can_drop_data(Vector2.ZERO, {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "flask_hp_minor"}) and not heal_cell._can_drop_data(Vector2.ZERO, {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "elixir_moonlight"}), "reliquary heal cell takes flasks only")
	_check(rp._potion_slots["tonic"]._can_drop_data(Vector2.ZERO, {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "tonic_graveluck"}) and not rp._potion_slots["tonic"]._can_drop_data(Vector2.ZERO, {"type": "other"}), "reliquary tonic cell takes tonics only")
	var slot := DmItemSlot.new()
	slot.set_item({"item_id": "elixir_moonlight", "name": "E"})
	slot.drag_data = {"type": DmHudBrewChip.DRAG_TYPE, "item_id": "elixir_moonlight"}
	_check(slot.drag_data is Dictionary and slot.is_filled(), "reliquary brew cell is a drag source")
	slot.free()
	chip.free()



func _last(game: DmMockGame, path: String) -> Dictionary:
	var c := game.calls_to(path)
	return c.back()["body"] if not c.is_empty() else {}


func _panels(game: DmMockGame, ui: DmGameUi) -> void:
	ui.close_panels()
	var pa: DmUiPanelsA = ui.pa
	var pb: DmUiPanelsB = ui.pb
	# Grimoire: rites, rune, loadouts
	ui.toggle_panel("grimoire")
	await _frames(3)
	var gv: DmGrimoireView = pa.grim_win.grimoire
	gv.assign_requested.emit(0, "corpse_explosion")
	_check(game.set_rites_calls.size() >= 1 and ui.rites.keys[0] == "corpse_explosion", "grimoire assign -> rites + game.set_rites")
	var rune_id: String = String(DmRunes.rites()[0])
	game.clear_calls()
	gv.rune_socket_requested.emit("bone_needle", "rune_splinter")
	await _frames(3)
	var rs := _last(game, "/api/inventory/rune")
	_check(rs.get("rite") == "bone_needle" and rs.get("itemId") == "rune_splinter", "rune socket -> rune_socket")
	game.replies["/api/loadouts/7"] = [{"slot": 0, "preset": {"name": "Main", "rites": {"primary": "bone_needle", "keys": ui.rites.keys}, "runes": {}, "weapon": null, "offhand": null}}]
	await pa.loadouts.load_rows()
	_check(pa.loadouts.rows.size() == 1, "loadouts listed")
	game.replies["/api/loadouts/apply"] = {"slots": game.slots, "report": {"skipped": [], "applied": [], "unchanged": false}, "preset": {}}
	game.clear_calls()
	await pa.loadouts._do_apply(0, pa.loadouts.rows[0]["preset"])
	_check(not game.calls_to("/api/loadouts/apply").is_empty(), "loadout apply via DmApi")
	game.clear_calls()
	pa.loadouts.naming = {"slot": 1, "rename": false}
	pa.loadouts.draw()
	pa.loadouts.name_edit.text = "Alt"
	await pa.loadouts.submit_name()
	var sv := _last(game, "/api/loadouts/save")
	_check(sv.get("slot") == 1 and sv["preset"]["name"] == "Alt", "loadout save via DmApi")
	ui.close_panels()
	# Legion
	ui.toggle_panel("legion")
	await _frames(3)
	game.clear_calls()
	pa.grim_win.legion.give_requested.emit(6)
	await _frames(3)
	var kg := _last(game, "/api/inventory/kit")
	_check(kg.get("slot_index") == 6 and kg.get("equipped") == 1, "legion give -> kit_move")
	pa.grim_win.legion.take_off_requested.emit("weapon")
	await _frames(3)
	_check(_last(game, "/api/inventory/kit").get("slot_index") == 120, "legion take off -> kit_move 120")
	pa.grim_win.legion.reinforce_requested.emit()
	await _frames(3)
	_check(not game.calls_to("/api/necro-progress/purchase").is_empty(), "reinforce -> necro_purchase")
	ui.close_panels()
	# Cosmetics
	ui.toggle_panel("cosmetics")
	await _frames(3)
	game.clear_calls()
	pa.char_win.cosmetics.cape_toggled.emit("cape_apprentice")
	await _frames(3)
	_check(_last(game, "/api/cosmetics/select").get("cape") == "cape_apprentice", "cape -> select_cosmetics")
	pa.char_win.cosmetics.adopt_requested.emit("pet_tithe_bat")
	await _frames(3)
	_check(_last(game, "/api/cosmetics/adopt").get("petId") == "pet_tithe_bat", "adopt -> adopt_pet")
	ui.close_panels()
	# Ascension
	ui.toggle_panel("ascension")
	await _frames(3)
	game.clear_calls()
	pa.ascension.ascend_confirmed.emit()
	pa.ascension.boon_buy_requested.emit("b")
	pa.ascension.unlock_requested.emit("vow:x")
	pa.ascension.vows_swear_requested.emit({})
	await _frames(4)
	for path in ["/api/necro-progress/ascend", "/api/necro-progress/boon", "/api/necro-progress/unlock", "/api/necro-progress/vows"]:
		_check(not game.calls_to(path).is_empty(), "ascension -> " + path)
	_check(game.refreshes["progress"] >= 4, "progress refreshed")
	ui.close_panels()
	# Class
	ui.toggle_panel("settings")
	await _frames(2)
	ui.set_ui.panel.action.emit("change_class")
	await _frames(3)
	_check(ui.is_open("class"), "change class opens the class panel")
	game.clear_calls()
	pa.class_panel.class_chosen.emit(6)
	await _frames(3)
	_check(_last(game, "/character/discipline").get("class_index") == 6, "class chosen -> change_discipline")
	ui.close_panels()
	# Waystone travel
	ui.toggle_panel("map")
	await _frames(2)
	pa.waystone.travel_requested.emit("graves")
	# GM rule: normal players see only unlocked areas, dev_access sees every non-instance area with a stone
	game.progress["unlocked"] = ["chapterhouse", "graves"]
	game.dev_access = false
	var ws: Array = pa._waystones()
	_check(ws == ["chapterhouse", "graves"], "waystones: normal player sees only unlocked areas")
	game.dev_access = true
	ws = pa._waystones()
	_check(ws.has("pyre") and ws.has("fen") and not ws.has("depths"), "waystones: dev_access lists pyre and fen, no instance")
	var order: Array = DmContent.area_order().filter(func(a): return ws.has(a))
	_check(ws == order, "waystones: dev_access list keeps area_order")
	game.dev_access = false
	# Acre tabs
	ui.toggle_panel("garden")
	await _frames(3)
	game.clear_calls()
	pb.garden.plant_requested.emit("bed_1", "seed_x", false)
	pb.garden.harvest_requested.emit("bed_1")
	await _frames(4)
	_check(not game.calls_to("/api/garden/plant").is_empty() and not game.calls_to("/api/garden/harvest").is_empty(), "garden plant/harvest -> DmApi")
	pb.labor.assign_requested.emit(0, "oak")
	pb.labor.collect_requested.emit(0)
	await _frames(4)
	_check(not game.calls_to("/api/labor/assign").is_empty() and not game.calls_to("/api/labor/collect").is_empty(), "labor assign/collect -> DmApi")
	pb.contracts.deliver_requested.emit(1)
	await _frames(3)
	_check(_last(game, "/api/contracts/deliver").get("slot") == 1, "contract deliver -> DmApi")
	ui.close_panels()
	# Forge, vault, salvage
	ui.toggle_panel("forge")
	await _frames(3)
	var f: DmForgePanel = pb.forges[""]
	game.clear_calls()
	f.craft_requested.emit("recipe_x", 2)
	await _frames(5)
	_check(game.calls_to("/api/craft").size() == 2, "craft x2 -> two craft calls")
	f.reforge_requested.emit(6, 0, 50)
	await _frames(3)
	_check(_last(game, "/api/reforge").get("slot_index") == 6, "reforge -> reforge_affix")
	ui.close_panels()
	game.area_id = "chapterhouse"
	ui.toggle_panel("vault")
	await _frames(3)
	game.clear_calls()
	pb.vault.deposit_requested.emit(4)
	await _frames(3)
	_check(not game.calls_to("/api/vault/deposit").is_empty(), "vault deposit -> DmApi")
	pb.vault.sort_requested.emit()
	await _frames(3)
	_check(not game.calls_to("/api/vault/sort").is_empty(), "vault sort -> DmApi")
	_check(not game.calls_to("/api/inventory/sort").is_empty(), "vault sort also sorts the bag (server)")
	game.clear_calls()
	pb.vault.move_requested.emit("bag", 4, "vault", 12, -1)
	await _frames(3)
	var mv: Dictionary = _last(game, "/api/vault/move")
	_check(mv.get("from") == "bag" and int(mv.get("fromSlot", -1)) == 4 and mv.get("to") == "vault" and int(mv.get("toSlot", -1)) == 12 and not mv.has("quantity"), "a Vault-window drop on a cell -> vault_move to exactly that slot (%s)" % mv)
	_check(game.calls_to("/api/inventory/save").is_empty(), "a move never saves the bag")
	game.clear_calls()
	ui.inv.panel.bag_move_requested.emit(4, 9)
	await _frames(3)
	var mb: Dictionary = _last(game, "/api/vault/move")
	_check(mb.get("from") == "bag" and mb.get("to") == "bag" and int(mb.get("fromSlot", -1)) == 4 and int(mb.get("toSlot", -1)) == 9, "a Reliquary bag drop on another cell -> vault_move bag to bag (%s)" % mb)
	ui.close_panels()
	ui.toggle_panel("salvage")
	await _frames(3)
	game.clear_calls()
	pb.salvage.salvage_requested.emit([3])
	await _frames(3)
	_check(_last(game, "/api/salvage").get("slots") == [3], "salvage -> salvage_gear")
	ui.close_panels()
	# reliquary: legion give from detail, tool belt offer, brew action
	ui.toggle_panel("inventory")
	await _frames(3)
	game.clear_calls()
	ui.inv.panel.action_requested.emit("belt", _card(ui, "elixir_moonlight"))
	_check(DmUiConfig.parse(ui.store.get_item(ui.belt_key())).get("elixir") == "elixir_moonlight", "detail 'Put on belt' sets the belt")
	ui.inv.panel.sel_item = _card(ui, "tool_pickaxe_iron")
	ui.inv.panel.refresh()
	_check(not ui.inv._extra_actions(_card(ui, "tool_pickaxe_iron")).is_empty(), "tool detail offers 'Put on belt'")
	ui.inv.panel.action_requested.emit("toolbelt", _card(ui, "tool_pickaxe_iron"))
	await _frames(3)
	_check(not game.calls_to("/api/inventory/belt").is_empty(), "detail tool belt -> belt_tool")
	game.clear_calls()
	ui.inv.panel.action_requested.emit("adopt", {"row": {"item_id": "charm_tithe_bat", "slot_index": 9}})
	await _frames(3)
	_check(_last(game, "/api/cosmetics/adopt").get("petId") == "pet_tithe_bat", "charm adopt from the bag")
	ui.close_panels()


func _extras(game: DmMockGame, ui: DmGameUi) -> void:
	ui.close_panels()
	game.game_event.emit("depths_stair_offer", {"deepest": 4})
	await _frames(3)
	_check(ui.is_open("depths_stair"), "depths stair offer opens the prompt")
	ui.stair_prompt.resume_button.pressed.emit()
	ui.close_panels()
	game.game_event.emit("boss_key_offer", {"boss": "gravedigger", "seals": 1, "gold": 999999, "shards": 0, "bound": false})
	await _frames(3)
	_check(ui.is_open("boss_key") and not ui.boss_key.emp_button.disabled and ui.boss_key.normal_button.disabled, "boss key: empowered affordable, normal needs shards")
	ui.close_panels()
	# tool belt offer: empty belt + bag tool
	var offer := ui.inv.belt_offer()
	_check(offer.size() == 1 and offer[0]["item_id"] == "tool_pickaxe_iron", "belt offer picks the best bag tool")
	# a belted tool counts as owned in the Professions tool line (Bug report #9031)
	var saved_slots: Array = game.slots
	game.slots = [{"slot_index": DmGathering.BELT_BASE + 1, "item_id": "tool_pickaxe_iron", "quantity": 1}]
	ui.pb._professions_data()
	_check(ui.pb.professions.tool_line("mining").begins_with("Tool: ") and ui.pb.professions.tool_line("mining").ends_with("on belt"), "belted pickaxe shows on the Professions tool line")
	game.slots = saved_slots
	# reveal logic
	_check(DmHudReveal.veteran_reveals({"level": 5, "gold": 0, "swap_ready": true, "has_gear": true}).has("menu.skills"), "veteran reveals")
	var r := DmHudReveal.new(9, DmCounselStore.new())
	_check(r.reveal("hud.shards", true) and r.is_new("hud.shards") and not r.reveal("hud.shards"), "reveal flags NEW once")
	r.clear("hud.shards")
	_check(not r.is_new("hud.shards"), "clear removes the NEW cue")
	var q := DmHudReveal.CueQueue.new()
	var got: Array = []
	q.show_cb = func(t: String, _k: String) -> void: got.append(t)
	q.push("a", "A")
	q.push("b", "B")
	_check(got == ["A"], "cue queue shows one at a time")
	q.tick(7.0)
	q.tick(1.0)
	_check(got == ["A", "B"], "cue queue advances after the hold")
	# rites sanitising
	var kit := DmAbilities.kit_for("necromancer")
	var rt := DmRites.new(3, kit, 1)
	_check(rt.keys.size() == (kit["hotbar"] as Array).size() and rt.primary == String(kit["defaultPrimary"]), "rites default for a fresh character")
	# bind rules
	_check(not DmUiBinds.check_bind({}, "loadout_1", "i")["ok"] and DmUiBinds.check_bind({}, "loadout_1", "f7")["ok"], "keybind: reserved refused, F7 ok")
	_check(not DmUiBinds.check_bind({}, "loadout_2", "f3")["ok"], "keybind: F3 belongs to the performance overlay (a saved F3 bind is dropped on load, which uses the same check)")
	_check(DmUiBinds.check_bind({}, "perf_overlay", "f3")["ok"] and DmUiBinds.check_bind({}, "perf_overlay", "f7")["ok"] and not DmUiBinds.check_bind({"perf_overlay": "f7"}, "loadout_1", "f7")["ok"], "keybind: the performance overlay may take F3 or another free key, and loadouts cannot take its key")
	DmUiBinds.save(null, {"perf_overlay": "f7"})
	_check(DmUiBinds.perf_key == "f7", "keybind: saving a perf overlay bind changes the key the overlay listens to")
	DmUiBinds.save(null, {})
	_check(DmUiBinds.perf_key == "f3", "keybind: clearing it returns the overlay to F3")
	_check(DmUiBinds.next_slot([0, 2, 5], 2, -1) == 5 and DmUiBinds.next_slot([0, 2, 5], 5, -1) == 0, "next loadout wraps")
	# clean name
	_check(DmLoadoutPresets.clean_name("  A<b>  c \u0001") == "Ab c", "loadout name cleaned")
	# legion text numbers
	var lines := DmLegionText.bonus_lines({"hp": 0.05, "damage": 0.096, "speed": 0.0, "ward": 0.0})
	_check(lines == ["Thralls hit +9.6% harder", "Thralls have +5% health"], "legion bonus lines")
	# necro weapon + brew text
	_check(DmUiBrews.necro_weapon_tooltip("staff_bone").get("level") == 1 and DmUiBrews.summary("elixir_moonlight").begins_with("Elixir"), "weapon tooltip + brew summary")


## An item card's stat row with a long meaning beside it, in a card as narrow as the tooltip: the stat ("+30 INT") stays on one line and the meaning wraps
## (2026-10-19, a team PC's screenshot: the stat was squeezed to one letter a line).
func _card_rows() -> void:
	var box := VBoxContainer.new()
	box.size = Vector2(340, 0)
	root.add_child(box)
	var card := DmItemCard.new()
	box.add_child(card)
	card.set_item({"name": "Brutal Staff of the Pale Moon", "rarity": "epic", "type_label": "Two-handed Weapon",
		"stats": [{"text": "+30 INT", "fx": "+39.0 spell power, +60 essence, +3.0 essence/s (+17.9 thrall damage)"}, {"text": "+6 VIT", "fx": "+48 health (+22 thrall health)"}]})
	await _frames(3)
	var stat_labels: Array = []
	for row in card.get_children():
		if row is HBoxContainer and row.get_child_count() == 2:
			stat_labels.append(row.get_child(0))
	_check(stat_labels.size() == 2, "the card has the two stat rows with a meaning (%d)" % stat_labels.size())
	for l in stat_labels:
		var lab := l as Label
		_check(lab.get_line_count() == 1 and lab.size.x + 0.5 >= lab.get_minimum_size().x, "\"%s\" stays on one line beside its long meaning (%d lines, %.0f px wide)" % [lab.text, lab.get_line_count(), lab.size.x])
	box.queue_free()
