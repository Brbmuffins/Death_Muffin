extends Control
## Screenshots of DmGameUi over a mock scene (mock DmGame, no server):  game_ui/shoot.sh <page> [out.png]
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
		"codex": ui.toggle_panel("codex")
		"acre": ui.toggle_panel("professions")
		"legion": ui.toggle_panel("legion")
	await get_tree().create_timer(1.6).timeout
	if _out != "":
		get_viewport().get_texture().get_image().save_png(_out)
	get_tree().quit()


func _first(ui: DmGameUi, id: String) -> Dictionary:
	for c in ui.inv.panel.bag:
		if not c.is_empty() and c["item_id"] == id:
			return c
	return {}
