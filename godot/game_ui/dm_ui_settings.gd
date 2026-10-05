class_name DmUiSettings
extends RefCounted
## Settings wiring (src/ui/MiscPanels.ts SettingsPanel + WorldScene's callbacks): DmSettingsPanel.values <-> game.settings, game.apply_settings,
## the panel's actions (leave, bug report, show tips again, change class, party), the loadout hotkey capture, and the Report a bug window.

var ui: Node
var game: Node
var panel: DmSettingsPanel
var report: DmBugReportView
var capturing := ""


func _init(ui_: Node) -> void:
	ui = ui_
	game = ui_.game
	panel = DmSettingsPanel.new()
	ui.windows["settings"] = panel
	ui.windows_root.add_child(panel)
	panel.changed.connect(_on_changed)
	panel.action.connect(_on_action)
	panel.bind_requested.connect(_on_bind_requested)
	panel.closed.connect(func() -> void: ui.panel_changed.emit())
	report = DmBugReportView.new()
	report.setup(ui)
	report.back_pressed.connect(close_bug_report)   # MiscPanels.openBugReport: Back = close() + open(), i.e. Settings again


func _options() -> void:
	var allowed := bool(game.character.get("auto_combat_allowed", false))
	panel.can_auto_combat = allowed
	panel.has_dev = bool(game.get("dev_account")) if game.get("dev_account") != null else false
	panel.has_bug_report = true
	panel.has_reset_tips = true
	panel.has_change_class = true
	panel.has_party = game.has_method("party_create")
	var pc: Variant = game.get("party_code")
	panel.party_code = String(pc) if pc != null else ""
	panel.has_keybinds = ui.is_necromancer()
	panel.binds = {}
	for a in DmUiBinds.ACTIONS:
		panel.binds[a] = DmUiBinds.label(ui.binds[a]) if ui.binds.has(a) else ""
	var kit: Dictionary = ui.kit()
	panel.kit_primary = String(DmAbilities.def(String(kit["defaultPrimary"]))["name"])
	panel.kit_corpse = String(DmAbilities.def(String(kit["rmb"]))["name"])
	panel.kit_legion = ui.is_necromancer()


func sync_values() -> void:
	for k in panel.values:
		if game.settings.has(k):
			panel.values[k] = game.settings[k]
	if panel.visible:
		panel.build()


func open() -> void:
	_detach_report()
	for k in game.settings:
		panel.values[k] = game.settings[k]
	panel.values["party_in"] = ""
	_options()
	panel.build()
	panel.open()


## Settings -> Report a bug swaps the Settings window's BODY for the form (the window, its header and its Esc stay); Back restores Settings.
func open_bug_report() -> void:
	if not panel.visible:
		open()
	for c in panel.body.get_children():
		panel.body.remove_child(c)
		c.queue_free()
	panel.body.add_child(report)
	panel.scroll.scroll_vertical = 0
	report.show_form()


func bug_report_open() -> bool:
	return report.get_parent() == panel.body


func close_bug_report() -> void:
	_detach_report()
	panel.close()
	open()


func _detach_report() -> void:
	if report.get_parent() != null:
		report.get_parent().remove_child(report)


func _on_changed(key: String, value: Variant) -> void:
	if key == "party_in":
		return
	ui.update_setting({key: value})


func _on_action(name: String) -> void:
	match name:
		"leave":
			ui.left_world.emit()
			ui.call_game_sync("leave_world")
		"bug_report":
			open_bug_report()
		"reset_tips":
			reset_tips()
		"change_class":
			ui.open_class_panel()
		"party_make":
			ui.call_game_sync("party_create")
		"party_join":
			ui.call_game_sync("party_join", [String(panel.values.get("party_in", "")).strip_edges()])
		"party_leave":
			ui.call_game_sync("party_leave")


## Settings "Show tips again": the counsel starts over, then walks the parts of the screen the player already has (WorldScene settings callback).
func reset_tips() -> void:
	var held: Dictionary = {}
	ui.counsel.show_tips_again({"atlas_revealed": ui.reveal.has("menu.atlas"), "spells_revealed": ui.reveal.has("hud.spells")})
	ui.toast("Covenant counsel will guide you again", "good")


func _on_bind_requested(action_id: String) -> void:
	capturing = action_id
	ui._bind_capture = action_id
	if panel.bind_note != null:
		panel.bind_note.text = "Press a key for %s (Esc clears)." % DmUiBinds.ACTION_LABEL[action_id]


## The next key press while a hotkey button waits (WorldScene binds.set via SettingsPanel capture).
func capture_key(e: InputEventKey) -> void:
	var aid := capturing
	capturing = ""
	ui._bind_capture = ""
	var name := DmUiBinds.key_name(e)
	var err := ""
	if name == "escape":
		ui.binds.erase(aid)
	else:
		var c := DmUiBinds.check_bind(ui.binds, aid, name)
		if c["ok"]:
			ui.binds[aid] = c["key"]
		else:
			err = String(c["error"])
	DmUiBinds.save(ui.store, ui.binds)
	panel.set_bind(aid, DmUiBinds.label(ui.binds[aid]) if ui.binds.has(aid) else "")
	if panel.bind_note != null:
		panel.bind_note.text = err if err != "" else "Click an action, then press a key. Esc clears it. Keys the game already uses are refused."
	ui.pa.grimoire_changed()
