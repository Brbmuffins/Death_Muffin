extends Control
## Counsel gallery: the HUD mock with one counsel card up and its TIP_ANCHOR glow lit.
## godot --path godot res://ui/onboarding/onboarding_gallery.tscn -- --tip=<tip id> [--page=calm|combat] [--out=/x.png] [--crop=x,y,w,h[,scale]]
## (ui/onboarding/shoot.sh wraps it in the renderer lock.)

var hud: DmHud
var counsel: DmCounsel
var view: DmCounselView
var _out := ""


func _ready() -> void:
	theme = DmUi.theme()
	var args := _args()
	_out = args.get("out", "")
	var tip: String = args.get("tip", "wave")
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
	hud.apply(DmHudMock.combat() if args.get("page", "calm") == "combat" else DmHudMock.calm())
	counsel = DmCounsel.new(1, DmCounselStore.new(), 0.0)
	counsel.key_for = func(a: String) -> String: return {"exhume": "2", "black_litany": "3"}.get(a, "")
	view = DmCounselView.new()
	view.setup(counsel, hud, DmCounselStore.new())
	add_child(view)
	counsel.show(tip, 0, {"kind": "calm"})
	counsel.tick(3.5)
	if _out != "":
		_capture.call_deferred()


func _process(delta: float) -> void:
	counsel.tick(delta)


func _args() -> Dictionary:
	var d := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1]
	return d


func _capture() -> void:
	for i in 16:
		await get_tree().process_frame
	# the glow breathes: wait to its fullest halo (0.7 s into the 1.4 s cycle)
	await get_tree().create_timer(0.35).timeout
	var img := get_viewport().get_texture().get_image()
	var a := _args()
	if a.has("crop"):
		var c := String(a["crop"]).split(",")
		img = img.get_region(Rect2i(int(c[0]), int(c[1]), int(c[2]), int(c[3])))
		if c.size() > 4:
			img.resize(int(img.get_width() * float(c[4])), int(img.get_height() * float(c[4])), Image.INTERPOLATE_LANCZOS)
	img.save_png(_out)
	print("saved ", _out, " ", img.get_size())
	get_tree().quit()
