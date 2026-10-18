extends Control
## Screenshots of DmGameUi over a mock scene (mock game, no server):  game_ui/shoot.sh <page> [out.png]
## pages: hud, inventory, sheet, grimoire, atlas, settings, codex, acre

var _out := ""
var _page := ""


func _ready() -> void:
	theme = DmUi.theme()
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_page = args.get("page", "hud")
	_out = args.get("out", "")
	var bg := ColorRect.new()
	bg.color = Color("14101a")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	DmUiConfig.dir = ""
	var game := DmMockGame.new()
	add_child(game)
	game.hud = DmHudMock.combat()
	game.hud["area_name"] = "The Hollow Graves"
	game.hud["minimap"] = DmHudMock.minimap()
	game.hud["brews"] = DmHudMock.brews()
	game.settings["hud_scale"] = float(args.get("hud_scale", "1.0"))
	var ui := DmGameUi.new()
	game.add_child(ui)
	ui.setup(game)
	await get_tree().create_timer(0.6).timeout
	match _page:
		"inventory":
			ui.toggle_panel("inventory")
			ui.inv.panel.sel_item = _first(ui, "staff_oak")
			ui.inv.panel.refresh()
		"sheet": ui.toggle_panel("sheet")
		"grimoire": ui.toggle_panel("grimoire")
		"atlas": ui.toggle_panel("atlas")
		"settings": ui.toggle_panel("settings")
		"hud": pass
		"codex": ui.toggle_panel("codex")
		"acre": ui.toggle_panel("professions")
		"legion": ui.toggle_panel("legion")
		"tip_item":
			ui.toggle_panel("inventory")
		"tip_spell": pass
		"belt_picker": pass
		"bug": ui.open_bug_report()
	await get_tree().create_timer(1.6).timeout
	match _page:
		"tip_item":
			var tip := DmTip.of(ui)
			var cell: DmItemSlot = null
			for sl in ui.inv.panel._slots:
				if sl.data.get("item_id", "") == "staff_bone" or (cell == null and sl.is_filled()):
					cell = sl
			var c := cell.get_global_rect().get_center()
			tip.test_mouse = c
			cell.show_tip()
			await get_tree().create_timer(0.6).timeout
		"tip_spell":
			var slot: DmHudSlot = ui.hud._slots[1]
			var tip2 := DmTip.of(ui)
			tip2.test_mouse = slot.button.get_global_rect().get_center()
			ui.hud._spell_hover(1, slot, true)
			await get_tree().create_timer(0.8).timeout
		"belt_picker":
			ui.belt_picker.toggle("elixir")
			await get_tree().create_timer(0.6).timeout
	if _out != "":
		get_viewport().get_texture().get_image().save_png(_out)
	get_tree().quit()


func _first(ui: DmGameUi, id: String) -> Dictionary:
	for c in ui.inv.panel.bag:
		if not c.is_empty() and c["item_id"] == id:
			return c
	return {}
