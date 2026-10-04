class_name DmBasicUi
extends CanvasLayer
## Fallback in-world UI until the game-ui track's DmGameUi is merged: the real DmHud fed by game.hud_state(), toasts / banners / loot lines /
## floating numbers from game_event, Esc opens the audio settings. Replaced by DmGameUi when godot/game_ui/ exists (see main.gd).

var game: DmGame
var hud: DmHud
var _floats_t := 0.0


func setup(g: DmGame) -> void:
	game = g
	layer = 10
	hud = DmHud.new()
	add_child(hud)
	g.game_event.connect(_on_event)
	hud.cast.connect(func(slot: int): g.cast(slot) if slot > 0 else g.input.cast_slot_primary())
	hud.navigate.connect(func(x: float, z: float): g.navigate(x, z))
	hud.buy_damage.connect(func(): g.buy_upgrade("damage"))
	hud.buy_wave.connect(func(): g.buy_upgrade("wave"))
	hud.toggle_auto_combat.connect(func(): g.set_auto_combat(not bool(g.settings["autoCombat"])))
	hud.belt_clicked.connect(func(slot: String): g.use_belt(slot))
	hud.dial_wave.connect(func(d: int): g.set_wave_tier(float(g.prog.local["waveTierActive"]) + d))


func _process(_dt: float) -> void:
	if game != null and game.ready_:
		hud.apply(game.hud_state())


func _on_event(id: String, ctx: Dictionary) -> void:
	match id:
		"toast": hud.toast(String(ctx["text"]), String(ctx.get("kind", "")))
		"banner": hud.banner(String(ctx["title"]), String(ctx.get("sub", "")), int(ctx.get("ms", 3200)))
		"loot": hud.loot_toast(String(ctx["name"]), int(ctx["quantity"]), String(ctx["rarity"]))
		"hit_flash": hud.hit_flash()
		"slot_flash": hud.slot_flash(int(ctx["slot"]))
		"float":
			if game.camera != null and bool(game.settings["damageNumbers"]) or String(ctx.get("kind", "")) not in ["hit", "crit"]:
				if game.camera != null:
					var v := Vector3(float(ctx["x"]), float(ctx["y"]), float(ctx["z"]))
					if not game.camera.is_position_behind(v):
						hud.float_text(game.camera.unproject_position(v), String(ctx["text"]), String(ctx.get("kind", "hit")))
