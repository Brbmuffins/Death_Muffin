extends Control
## HUD gallery (own scene; the UI-kit gallery is untouched). godot --path godot res://ui/hud/hud_gallery.tscn -- --page=combat|boss|calm|death|events --out=/x.png
## Pages are the mock view-models in dm_hud_mock.gd; "events" fires the one-shot calls (toasts, banner, floating numbers, chat).

var hud: DmHud
var _out := ""
var _page := ""


func _ready() -> void:
	theme = DmUi.theme()
	var args := _args()
	_page = args.get("page", "combat")
	_out = args.get("out", "")
	if args.has("w"):
		get_window().size = Vector2i(int(args["w"]), int(args.get("h", "800")))
	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var grad := GradientTexture2D.new()
	grad.gradient = Gradient.new()
	grad.gradient.colors = PackedColorArray([Color("1b1624"), Color("0a080d")])
	grad.fill = GradientTexture2D.FILL_RADIAL
	grad.fill_from = Vector2(0.5, 0.45)
	grad.fill_to = Vector2(1.0, 1.0)
	bg.texture = grad
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(bg)
	hud = DmHud.new()
	add_child(hud)
	match _page:
		"boss": hud.apply(DmHudMock.boss())
		"calm": hud.apply(DmHudMock.calm())
		"death":
			var v := DmHudMock.combat()
			v["hp"] = 0
			v["death"] = {"show": true, "sub": "The Covenant will carry you back."}
			hud.apply(v)
		"events":
			var e := DmHudMock.combat()
			e["target"] = null
			hud.apply(e)
		_: hud.apply(DmHudMock.combat())
	if _page == "calm":
		var tip := DmTipCard.new()
		add_child(tip)
		tip.set_tip("Wave Speed", "Open the <b>Altar</b> or press <kbd>U</kbd> to quicken the waves.", 60000)
		tip.position = hud.tip_default_position()
		hud.banner("The Chapterhouse", "Sanctuary of the Ossuary Covenant", 60000)
	if _page == "combat" or _page == "events":
		_events.call_deferred()
	if _out != "":
		_capture.call_deferred()


func _events() -> void:
	hud.toast("Level 31 reached", "good")
	hud.toast("Not enough essence", "err")
	hud.toast("Wave Speed unlocked: spend gold at the Altar", "new")
	hud.loot_toast("Bone Dust", 1, "common")
	hud.loot_toast("Bone Dust", 2, "common")
	hud.loot_toast("Gravewrought Mantle", 1, "epic")
	hud.chat_line("Helix: behind you!")
	hud.chat_line("Moth: on my way")
	var c := get_viewport_rect().size * 0.5
	hud.float_text(c + Vector2(-150, -90), "1,204", "crit")
	hud.float_text(c + Vector2(-60, -30), "312", "hit")
	hud.float_text(c + Vector2(40, -120), "88", "dot")
	hud.float_text(c + Vector2(120, -60), "64", "thrall")
	hud.float_text(c + Vector2(-210, 0), "-140", "hurt")
	hud.float_text(c + Vector2(190, -20), "+320", "heal")
	hud.float_text(c + Vector2(0, 40), "+48g", "gold")
	hud.float_text(c + Vector2(-100, 70), "Corpse Explosion", "skill")
	hud.hit_flash()


func _args() -> Dictionary:
	var d := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1]
	return d


func _capture() -> void:
	var quick := _page == "events" or _page == "combat"
	var frames := 4 if quick else 14
	for i in frames:
		await get_tree().process_frame
	await get_tree().create_timer(0.2 if quick else 0.45).timeout
	var img := get_viewport().get_texture().get_image()
	var a := _args()
	if a.has("crop"):  # --crop=x,y,w,h[,scale]  (zoomed detail shots)
		var c := String(a["crop"]).split(",")
		img = img.get_region(Rect2i(int(c[0]), int(c[1]), int(c[2]), int(c[3])))
		if c.size() > 4:
			img.resize(int(img.get_width() * float(c[4])), int(img.get_height() * float(c[4])), Image.INTERPOLATE_LANCZOS)
	img.save_png(_out)
	print("saved ", _out, " ", img.get_size())
	get_tree().quit()
