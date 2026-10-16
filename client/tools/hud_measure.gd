extends SceneTree
## The HUD's draw-call and CPU measurement (client/README.md "The HUD's budget"). A RENDERED run: Forward+ on the software Vulkan driver (lavapipe); draw-call
## counts do not depend on the GPU. It starts the game scene with the full HUD in a Full Party-like crowd (72 enemies, 32 thralls, floating numbers kept at their caps)
## and reads the engine's draw-call counter with the HUD hidden and shown, for the HUD as the game scene shows it ("game") and with every piece on and fed ("full").
##
## Phases, in this order, each writing its lines before the next starts (a run cut off by the caller's timeout keeps what it got): the scene is built with nothing drawn (the first drawn frame of
## a software Vulkan device takes tens of seconds); the HUD's draw calls and CPU cost; the screenshot (--shot); --fidelity (each replacement against the primitive it replaced, pixel by pixel);
## --micro (which drawing commands share a draw call; --micro-all adds the older cases); the breakdown (each HUD piece alone, and the parts of the costly ones; unless --no-breakdown).
## The 3D scene behind the HUD is not drawn unless --3d (the HUD's draw calls do not depend on it).
##
##   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1600x900x24" \
##     timeout 55 /home/ubuntu/tools/godot/godot --path client --rendering-driver vulkan --resolution 1280x720 --fixed-fps 60 \
##     --script res://tools/hud_measure.gd -- --out=<file.jsonl> [--shot=<png>] [--micro] [--fidelity] [--no-breakdown] [--3d] [--budget=<seconds>]
##
## `--budget` is the caller's timeout less five seconds (default 50): later phases are skipped once it has passed. Headless it runs the same code with every count 0 (the logic is
## checked that way; the counts need a renderer).

const BUDGET := 150
const LEGIONS := ["ossuary", "gravecaller", "rotweaver", "mourner"]
const THRALL_BASE := {"warrior": [1.3, 1.0, 5.6], "shieldbearer": [1.3, 1.25, 5.2], "hound": [1.2, 0.7, 7.2], "wraith": [5.5, 1.1, 5.8],
	"archer": [7.5, 1.3, 5.4], "bonemage": [6.5, 1.8, 5.2], "plaguebearer": [1.3, 1.2, 4.8]}

var out_path := ""
var shot_path := ""
var out: FileAccess
var g: DmNextGame
var layer: CanvasLayer          ## the micro experiments' layer
var micro_host: Control
var hud_layer: HudShim             # today's HUD and panels as the measurement drives them (tests/hud_shim.gd)
var fps_now_ms := 0.0           ## the game clock the floats' caps count in (each rendered frame is 1/60 s under --fixed-fps)
var spam_n := 0
var budget_s := 50
var bd: Control                 ## the HUD the breakdown takes apart (a DmHud: it has `safe`)
var headless := false


func _initialize() -> void:
	headless = DisplayServer.get_name() == "headless"
	# Nothing is drawn until the scene is built: the first drawn frame of a software Vulkan device takes tens of seconds (pipelines), and the caller's timeout is 55 s in all.
	RenderingServer.render_loop_enabled = false
	root.disable_3d = true
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--out="):
			out_path = a.substr(6)
		elif a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--budget="):
			budget_s = int(a.substr(9))
	if out_path != "":
		out = FileAccess.open(out_path, FileAccess.WRITE)
	emit({"event": "start", "renderer": RenderingServer.get_video_adapter_name(), "api": RenderingServer.get_video_adapter_api_version(), "window": str(DisplayServer.window_get_size()),
		"headless": DisplayServer.get_name() == "headless", "args": str(args)})
	await process_frame
	await game_stage(args)
	emit({"event": "done"})
	quit(0)


func emit(d: Dictionary) -> void:
	d["t"] = snappedf(float(Time.get_ticks_msec()) / 1000.0, 0.01)   # since the process started
	var line := JSON.stringify(d)
	print(line)
	if out != null:
		out.store_line(line)
		out.flush()


## True when the caller's timeout is near (`--budget=<seconds>`, default 50 for a 55 s limit; the engine's own start-up counts: ticks run from the process start).
func late() -> bool:
	return Time.get_ticks_msec() > budget_s * 1000


# ---- reading the counters ---------------------------------------------------------------------------------------------------------------

## The next drawn frame (headless there is no drawing: the next processed one).
func next_frame() -> void:
	if headless:
		await process_frame
	else:
		await RenderingServer.frame_post_draw


func read() -> Dictionary:
	var vp := root.get_viewport_rid()
	return {
		"total": int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)),
		"canvas": int(RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_CANVAS, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)),
		"scene": int(RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)),
		"shadow": int(RenderingServer.viewport_get_render_info(vp, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)),
	}


## Waits `n` rendered frames and returns the last one's counters (the earlier frames let layout, redraws and tweens settle). `each` runs before every frame.
func frames(n: int, each: Callable = Callable()) -> Dictionary:
	for i in n:
		if each.is_valid():
			each.call()
		await next_frame()
	return read()


# ---- micro experiments: what a primitive costs in draw calls ------------------------------------------------------------------------------

class Painter extends Control:
	var fn: Callable
	func _init(f: Callable, sz := Vector2(1600, 900)) -> void:
		fn = f
		size = sz
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		fn.call(self)


func micro_setup() -> void:
	layer = CanvasLayer.new()
	root.add_child(layer)
	micro_host = Control.new()
	micro_host.size = Vector2(1600, 900)
	layer.add_child(micro_host)
	DmHudAtlas.ensure()


func micro_teardown() -> void:
	for c in micro_host.get_children():
		c.free()
	layer.queue_free()


## The cases the HUD's design rests on: which kinds of commands share a draw call when they are consecutive on one z layer.
func micro_batching() -> void:
	var a := DmHudAtlas.texture
	var w := DmHudAtlas.white()
	var tex1: Texture2D = DmHudAtlas.icon("res://assets/game/art/status/chilled.webp", 64)
	var tex2: Texture2D = DmHudAtlas.icon("res://assets/game/art/status/withered.webp", 64)
	var np := DmHudKit.plate(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), Vector4(1, 1, 1, 1), Vector4(4, 4, 4, 4), 2)
	var body: Font = DmUi.font("body")
	await m("atlas: 9-patch, white rect, icon, alternating x10", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 10:
			np.draw(c.get_canvas_item(), Rect2(10 + i * 80, 10, 70, 24))
			DmHudKit.rect(c, Rect2(10 + i * 80, 40, 70, 4), Color.RED)
			c.draw_texture_rect(tex1, Rect2(10 + i * 80, 50, 24, 24), false)
			c.draw_texture_rect(tex2, Rect2(40 + i * 80, 50, 24, 24), false))))
	await m("atlas: rect and icon alternating x10 (no 9-patch)", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 10:
			DmHudKit.rect(c, Rect2(10 + i * 80, 40, 70, 4), Color.RED)
			c.draw_texture_rect(tex1, Rect2(10 + i * 80, 50, 24, 24), false)
			c.draw_texture_rect(tex2, Rect2(40 + i * 80, 50, 24, 24), false))))
	await m("atlas: 9-patch x20 only", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			np.draw(c.get_canvas_item(), Rect2(10 + (i % 10) * 80, 10 + (i / 10) * 30, 70, 24)))))
	await m("atlas rect, clip_uv true vs false alternating x10", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 10:
			c.draw_texture_rect_region(a, Rect2(10 + i * 80, 40, 70, 4), w, Color.RED, false, true)
			c.draw_texture_rect_region(a, Rect2(10 + i * 80, 50, 70, 4), w, Color.RED, false, false))))
	await m("layers: panel z0, rect+icon z1, text z4+ x10 chips (the HUD's pattern)", func() -> void:
		for i in 10:
			var p := PanelContainer.new()
			p.add_theme_stylebox_override("panel", np)
			p.position = Vector2(10, 10 + i * 40)
			p.custom_minimum_size = Vector2(160, 30)
			p.size = Vector2(160, 30)
			micro_host.add_child(p)
			var r := Painter.new(func(c: Control) -> void:
				DmHudKit.rect(c, Rect2(6, 6, 20, 4), Color.RED)
				c.draw_texture_rect(tex1, Rect2(30, 4, 22, 22), false), Vector2(100, 30))
			r.position = Vector2(10, 10 + i * 40)
			r.z_index = DmHudKit.Z_CHROME
			micro_host.add_child(r)
			var l := DmHudKit.lbl("BONE WARD", 12, Color.WHITE, "body", true, 2.0)
			l.position = Vector2(70, 14 + i * 40)
			micro_host.add_child(l))
	await m("layers: the same without layers (z all 0)", func() -> void:
		for i in 10:
			var p := PanelContainer.new()
			p.add_theme_stylebox_override("panel", np)
			p.position = Vector2(10, 10 + i * 40)
			p.custom_minimum_size = Vector2(160, 30)
			p.size = Vector2(160, 30)
			micro_host.add_child(p)
			var r := Painter.new(func(c: Control) -> void:
				DmHudKit.rect(c, Rect2(6, 6, 20, 4), Color.RED)
				c.draw_texture_rect(tex1, Rect2(30, 4, 22, 22), false), Vector2(100, 30))
			r.position = Vector2(10, 10 + i * 40)
			micro_host.add_child(r)
			var l := Label.new()
			l.text = "BONE WARD"
			l.add_theme_font_override("font", body)
			l.add_theme_font_size_override("font_size", 12)
			l.position = Vector2(70, 14 + i * 40)
			micro_host.add_child(l))
	await m("text: 10 labels size 12 and 10 labels size 13, two text layers", func() -> void:
		for i in 20:
			var l := DmHudKit.lbl("Level %d" % i, 12 + (i % 2), Color.WHITE, "body", true)
			l.position = Vector2(10 + (i % 2) * 150, 10 + (i / 2) * 20)
			micro_host.add_child(l))
	await m("text: 10 plain labels and 10 letter-spaced ones, same font and size", func() -> void:
		for i in 20:
			var l := DmHudKit.lbl("LEVEL %d" % i, 12, Color.WHITE, "body", true, 2.0 if i % 2 == 0 else 0.0)
			l.position = Vector2(10 + (i % 2) * 150, 10 + (i / 2) * 20)
			micro_host.add_child(l))
	await m("draw_primitive triangle x50", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 50:
			c.draw_primitive(PackedVector2Array([Vector2(10 + i * 10, 10), Vector2(18 + i * 10, 10), Vector2(14 + i * 10, 20)]), PackedColorArray([Color.RED, Color.RED, Color.RED]), PackedVector2Array()))))
	await m("draw_primitive quad x20", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_primitive(PackedVector2Array([Vector2(10 + i * 30, 10), Vector2(30 + i * 30, 10), Vector2(30 + i * 30, 30), Vector2(10 + i * 30, 30)]), PackedColorArray([Color.RED, Color.RED, Color.RED, Color.RED]), PackedVector2Array()))))
	var bag := DmHudMesh.new()
	for i in 100:
		bag.rect(Rect2(10 + (i % 40) * 8, 10 + (i / 40) * 8, 6, 6), Color.from_hsv(i / 100.0, 1, 1))
	var bag_mesh := bag.to_mesh()
	_keep.append(bag_mesh)
	await m("one DmHudMesh of 100 quads, canvas_item_add_triangle_array (one command)", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void: bag.submit(c))))
	await m("the same bag as an ArrayMesh, draw_mesh", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void: c.draw_mesh(bag_mesh, null))))
	await m("three meshes on one item", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		c.draw_mesh(bag_mesh, null)
		c.draw_mesh(bag_mesh, null, Transform2D(0.0, Vector2(0, 100)))
		bag.submit(c))))
	var mm := multi(100)
	var mm4 := multi(400)
	_keep.append(mm)
	_keep.append(mm4)
	await m("multimesh 100 instances (draw_multimesh)", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void: c.draw_multimesh(mm, null))))
	await m("multimesh 400 instances", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void: c.draw_multimesh(mm4, null))))
	await m("the minimap's disc: clip_children + MultiMesh of 150 dots + one mesh", func() -> void:
		var disc := Painter.new(func(c: Control) -> void: c.draw_circle(Vector2(95, 95), 95.0, Color.BLUE), Vector2(190, 190))
		disc.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		var dm := multi(150)
		_keep.append(dm)
		disc.add_child(Painter.new(func(c: Control) -> void:
			c.draw_multimesh(dm, null)
			bag.submit(c), Vector2(190, 190)))
		micro_host.add_child(disc))
	await m("the 1.5 px lines of a pip row as DmHudMesh quads: 12 diamonds in one mesh", func() -> void:
		var d := DmHudParts.Diamonds.new()
		d.set_state([true, true, true, 2, 2, true, false, false, false, false, false, false])
		d.position = Vector2(20, 20)
		micro_host.add_child(d))


var _keep: Array = []   ## meshes the draw commands refer to by RID: they must outlive the frame


## The draw calls cut off, one frame, and read: the cost of a measurement is a frame, so this is cheap.
func micro() -> void:
	var body: Font = DmUi.font("body")
	var num: Font = DmUi.font("numeric")
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 5
	var textures: Array[ImageTexture] = []
	for i in 24:
		var im := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		im.fill(Color(rnd.randf(), rnd.randf(), rnd.randf(), 1.0))
		textures.append(ImageTexture.create_from_image(im))
	var atlas_img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	atlas_img.fill(Color.WHITE)
	var atlas := ImageTexture.create_from_image(atlas_img)
	var sb_fill := func(c: Color) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		return sb
	var sb_border := func(c: Color, b: Color, r: int) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = c
		sb.border_color = b
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(r)
		return sb
	await m("empty", func() -> void: pass)
	await m("rect x1", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void: c.draw_rect(Rect2(10, 10, 60, 20), Color.RED))))
	await m("rect x20 one item", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_rect(Rect2(10, 10 + i * 30, 60, 20), Color.RED))))
	await m("rect x20 one item, 20 colours", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_rect(Rect2(10, 10 + i * 30, 60, 20), Color.from_hsv(i / 20.0, 1, 1)))))
	await m("rect x20 in 20 items", func() -> void:
		for i in 20:
			micro_host.add_child(Painter.new(func(c: Control) -> void: c.draw_rect(Rect2(10, 10 + i * 30, 60, 20), Color.RED))))
	await m("rect outline x20 one item", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_rect(Rect2(10, 10 + i * 30, 60, 20), Color.RED, false, 1.0))))
	await m("rect outline width 2 x20", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_rect(Rect2(10, 10 + i * 30, 60, 20), Color.RED, false, 2.0))))
	await m("circle x20 one item", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_circle(Vector2(30 + i * 20, 100), 5.0, Color.RED))))
	await m("circle x20 in 20 items", func() -> void:
		for i in 20:
			micro_host.add_child(Painter.new(func(c: Control) -> void: c.draw_circle(Vector2(30 + i * 20, 100), 5.0, Color.RED))))
	await m("colored polygon x20", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_colored_polygon(PackedVector2Array([Vector2(10 + i * 30, 10), Vector2(30 + i * 30, 10), Vector2(30 + i * 30, 30), Vector2(10 + i * 30, 30)]), Color.RED))))
	await m("polygon with vertex colours x20", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_polygon(PackedVector2Array([Vector2(10 + i * 30, 10), Vector2(30 + i * 30, 10), Vector2(30 + i * 30, 30), Vector2(10 + i * 30, 30)]), PackedColorArray([Color.RED, Color.GREEN, Color.GREEN, Color.RED])))))
	await m("line x20 width 1", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_line(Vector2(10, 10 + i * 20), Vector2(100, 10 + i * 20), Color.RED, 1.0))))
	await m("line x20 width 2 antialiased", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_line(Vector2(10, 10 + i * 20), Vector2(100, 10 + i * 20), Color.RED, 2.0, true))))
	await m("polyline x20 (4 points)", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_polyline(PackedVector2Array([Vector2(10, 10 + i * 20), Vector2(50, 20 + i * 20), Vector2(90, 10 + i * 20), Vector2(130, 20 + i * 20)]), Color.RED, 1.0))))
	await m("polyline x20 antialiased", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_polyline(PackedVector2Array([Vector2(10, 10 + i * 20), Vector2(50, 20 + i * 20), Vector2(90, 10 + i * 20), Vector2(130, 20 + i * 20)]), Color.RED, 1.0, true))))
	await m("arc x20", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_arc(Vector2(40 + i * 30, 100), 10.0, 0.0, TAU, 24, Color.RED, 2.0, true))))
	await m("draw_string x20 same font", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_string(body, Vector2(10, 20 + i * 20), "Health 123 / 456", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE))))
	await m("draw_string x20 alternating two sizes", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_string(body, Vector2(10, 20 + i * 20), "Health 123 / 456", HORIZONTAL_ALIGNMENT_LEFT, -1, 14 + (i % 2) * 4, Color.WHITE))))
	await m("draw_string x20 alternating two fonts", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_string(body if i % 2 == 0 else num, Vector2(10, 20 + i * 20), "Health 123 / 456", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE))))
	await m("draw_string x20 outline then fill, interleaved", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_string_outline(num, Vector2(10, 20 + i * 20), "123", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, 3, Color.BLACK)
			c.draw_string(num, Vector2(10, 20 + i * 20), "123", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color.WHITE))))
	await m("draw_string x20 all outlines then all fills", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_string_outline(num, Vector2(10, 20 + i * 20), "123", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, 3, Color.BLACK)
		for i in 20:
			c.draw_string(num, Vector2(10, 20 + i * 20), "123", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color.WHITE))))
	await m("label x20 same font", func() -> void:
		for i in 20:
			micro_host.add_child(label("Health 123 / 456", body, 14, Vector2(10, 10 + i * 20), false)))
	await m("label x20 with shadow", func() -> void:
		for i in 20:
			micro_host.add_child(label("Health 123 / 456", body, 14, Vector2(10, 10 + i * 20), true)))
	await m("label x20 with outline 3 (the floating numbers)", func() -> void:
		for i in 20:
			var l := label("%d" % (100 + i), num, 17, Vector2(10, 10 + i * 20), false)
			l.add_theme_constant_override("outline_size", 3)
			l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
			micro_host.add_child(l))
	await m("label x20 alternating two fonts", func() -> void:
		for i in 20:
			micro_host.add_child(label("Health 123 / 456", body if i % 2 == 0 else num, 14, Vector2(10, 10 + i * 20), false)))
	await m("label x20 in two columns, z_index 1 on the second", func() -> void:
		for i in 20:
			var l := label("Health 123 / 456", body if i % 2 == 0 else num, 14, Vector2(10 + (i % 2) * 200, 10 + (i / 2) * 20), false)
			l.z_index = i % 2
			micro_host.add_child(l))
	await m("panel x20 flat fill (StyleBoxFlat)", func() -> void:
		for i in 20:
			micro_host.add_child(panel(sb_fill.call(Color(0.1, 0.1, 0.2, 0.8)), Vector2(10, 10 + i * 30), Vector2(100, 24))))
	await m("panel x20 fill + 1px border", func() -> void:
		for i in 20:
			micro_host.add_child(panel(sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 0), Vector2(10, 10 + i * 30), Vector2(100, 24))))
	await m("panel x20 fill + border + radius 3", func() -> void:
		for i in 20:
			micro_host.add_child(panel(sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 3), Vector2(10, 10 + i * 30), Vector2(100, 24))))
	await m("panel x20 fill + border + radius 3, no anti-aliasing", func() -> void:
		for i in 20:
			var sb: StyleBoxFlat = sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 3)
			sb.anti_aliasing = false
			micro_host.add_child(panel(sb, Vector2(10, 10 + i * 30), Vector2(100, 24))))
	await m("panel x20 fill + border + shadow", func() -> void:
		for i in 20:
			var sb: StyleBoxFlat = sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 2)
			sb.shadow_size = 12
			sb.shadow_color = Color(0, 0, 0, 0.6)
			micro_host.add_child(panel(sb, Vector2(10, 10 + i * 30), Vector2(100, 24))))
	await m("panel + label x10 pairs (typical chip)", func() -> void:
		for i in 10:
			micro_host.add_child(panel(sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 2), Vector2(10, 10 + i * 40), Vector2(160, 30)))
			micro_host.add_child(label("BONE WARD", body, 12, Vector2(20, 14 + i * 40), true)))
	await m("panel + label x10 pairs, labels at z_index 1", func() -> void:
		for i in 10:
			micro_host.add_child(panel(sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 2), Vector2(10, 10 + i * 40), Vector2(160, 30)))
			var l := label("BONE WARD", body, 12, Vector2(20, 14 + i * 40), true)
			l.z_index = 1
			micro_host.add_child(l))
	await m("panel x10 then label x10 (grouped)", func() -> void:
		for i in 10:
			micro_host.add_child(panel(sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 2), Vector2(10, 10 + i * 40), Vector2(160, 30)))
		for i in 10:
			micro_host.add_child(label("BONE WARD", body, 12, Vector2(20, 14 + i * 40), true)))
	await m("button x10 with styleboxes", func() -> void:
		for i in 10:
			var b := Button.new()
			b.text = "Bag"
			b.position = Vector2(10, 10 + i * 40)
			b.size = Vector2(60, 30)
			b.add_theme_stylebox_override("normal", sb_border.call(Color(0.1, 0.1, 0.2, 0.8), Color(0.5, 0.5, 0.5), 0))
			micro_host.add_child(b))
	await m("texture rect x20 same texture", func() -> void:
		for i in 20:
			micro_host.add_child(tex_rect(textures[0], Vector2(10 + i * 40, 10))))
	await m("texture rect x20 same texture, different modulate", func() -> void:
		for i in 20:
			var t := tex_rect(textures[0], Vector2(10 + i * 40, 10))
			t.modulate = Color.from_hsv(i / 20.0, 0.6, 1.0)
			micro_host.add_child(t))
	await m("texture rect x20 different textures", func() -> void:
		for i in 20:
			micro_host.add_child(tex_rect(textures[i], Vector2(10 + i * 40, 10))))
	await m("texture rect x20 atlas regions of one atlas", func() -> void:
		for i in 20:
			var at := AtlasTexture.new()
			at.atlas = atlas
			at.region = Rect2((i % 8) * 32, (i / 8) * 32, 32, 32)
			micro_host.add_child(tex_rect(at, Vector2(10 + i * 40, 10))))
	await m("draw_texture_rect x20 same texture, one item", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 20:
			c.draw_texture_rect(textures[0], Rect2(10 + i * 40, 10, 32, 32), false))))
	await m("rects and a texture alternating x10", func() -> void: micro_host.add_child(Painter.new(func(c: Control) -> void:
		for i in 10:
			c.draw_rect(Rect2(10 + i * 80, 10, 60, 20), Color.RED)
			c.draw_texture_rect(textures[0], Rect2(10 + i * 80, 40, 32, 32), false))))
	await m("nine-patch (StyleBoxTexture) x20 same texture", func() -> void:
		for i in 20:
			var st := StyleBoxTexture.new()
			st.texture = atlas
			st.region_rect = Rect2(0, 0, 16, 16)
			st.set_texture_margin_all(4)
			micro_host.add_child(panel(st, Vector2(10, 10 + i * 30), Vector2(100, 24))))
	await m("nine-patch x20 atlas regions, different modulate", func() -> void:
		for i in 20:
			var st := StyleBoxTexture.new()
			st.texture = atlas
			st.region_rect = Rect2((i % 4) * 16, 0, 16, 16)
			st.set_texture_margin_all(4)
			st.modulate_color = Color.from_hsv(i / 20.0, 0.5, 1.0)
			micro_host.add_child(panel(st, Vector2(10, 10 + i * 30), Vector2(100, 24))))
	await m("clip_contents x10", func() -> void:
		for i in 10:
			var p := Painter.new(func(c: Control) -> void: c.draw_rect(Rect2(0, 0, 60, 20), Color.RED), Vector2(80, 30))
			p.position = Vector2(10, 10 + i * 40)
			p.clip_contents = true
			micro_host.add_child(p))
	await m("clip_children (the minimap's disc) x1", func() -> void:
		var disc := Painter.new(func(c: Control) -> void: c.draw_circle(Vector2(95, 95), 95.0, Color.BLUE), Vector2(190, 190))
		disc.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		disc.add_child(Painter.new(func(c: Control) -> void: c.draw_rect(Rect2(0, 0, 100, 100), Color.RED), Vector2(190, 190)))
		micro_host.add_child(disc))
	await m("clip_children x1 with 100 circles inside", func() -> void:
		var disc := Painter.new(func(c: Control) -> void: c.draw_circle(Vector2(95, 95), 95.0, Color.BLUE), Vector2(190, 190))
		disc.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		disc.add_child(Painter.new(func(c: Control) -> void:
			for i in 100:
				c.draw_circle(Vector2(10 + (i % 10) * 17, 10 + (i / 10) * 17), 3.0, Color.RED), Vector2(190, 190)))
		micro_host.add_child(disc))
	await m("modulate on 10 panels", func() -> void:
		for i in 10:
			var p := panel(sb_fill.call(Color(0.1, 0.1, 0.2, 0.8)), Vector2(10, 10 + i * 30), Vector2(100, 24))
			p.modulate.a = 0.5
			micro_host.add_child(p))
	await m("texture rect x6 with one ShaderMaterial", func() -> void:
		var sh := Shader.new()
		sh.code = "shader_type canvas_item;\nuniform float sat = 1.0;\nvoid fragment(){ vec4 c = texture(TEXTURE, UV); float g = dot(c.rgb, vec3(0.299,0.587,0.114)); c.rgb = mix(vec3(g), c.rgb, sat); COLOR = c; }\n"
		var mat := ShaderMaterial.new()
		mat.shader = sh
		for i in 6:
			var t := tex_rect(textures[i], Vector2(10 + i * 40, 10))
			t.material = mat
			micro_host.add_child(t))
	await m("rich text label x5", func() -> void:
		for i in 5:
			var r := RichTextLabel.new()
			r.bbcode_enabled = true
			r.fit_content = true
			r.scroll_active = false
			r.text = "[center]%d slain here · Level 1 dead[/center]" % i
			r.position = Vector2(10, 10 + i * 30)
			r.size = Vector2(200, 24)
			micro_host.add_child(r))
	await m("HBoxContainer of 8 label+icon chips", func() -> void:
		var hb := HBoxContainer.new()
		hb.position = Vector2(10, 10)
		for i in 8:
			hb.add_child(tex_rect(textures[i], Vector2.ZERO))
			hb.add_child(label("x%d" % i, num, 12, Vector2.ZERO, true))
		micro_host.add_child(hb))
	await m("subviewport cache: the frame that renders it", func() -> void: micro_host.add_child(cached_chrome()), 1)
	await m("subviewport cache: settled (update stopped)", func() -> void: micro_host.add_child(cached_chrome()), 5)


## One experiment: clear the host, build, let `n` frames pass, report the last frame's counters.
func m(name: String, build: Callable, n := 3) -> void:
	if late():
		return
	for c in micro_host.get_children():
		micro_host.remove_child(c)
		c.free()
	build.call()
	var r := await frames(n)
	r["event"] = "micro"
	r["name"] = name
	emit(r)


func label(text: String, font: Font, size: int, pos: Vector2, shadow: bool) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	if shadow:
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("shadow_offset_y", 1)
	return l


func panel(sb: StyleBox, pos: Vector2, sz: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", sb)
	p.position = pos
	p.custom_minimum_size = sz
	p.size = sz
	return p


func tex_rect(t: Texture2D, pos: Vector2) -> TextureRect:
	var r := TextureRect.new()
	r.texture = t
	r.position = pos
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.custom_minimum_size = Vector2(32, 32)
	r.size = Vector2(32, 32)
	return r


func multi(n: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	var q := QuadMesh.new()
	q.size = Vector2(4, 4)
	mm.mesh = q
	mm.instance_count = n
	for i in n:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2(20 + (i % 40) * 8, 20 + (i / 40) * 8)))
		mm.set_instance_color(i, Color.from_hsv(i / float(n), 1, 1))
	return mm


func quads(n: int) -> ArrayMesh:
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for i in n:
		var o := Vector2(20 + (i % 40) * 8, 20 + (i / 40) * 8)
		var b := verts.size()
		verts.append_array([o, o + Vector2(4, 0), o + Vector2(4, 4), o + Vector2(0, 4)])
		for k in 4:
			cols.append(Color.from_hsv(i / float(n), 1, 1))
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## A little chrome (10 panels with a label each) rendered by a SubViewport that updates once, shown by one TextureRect: what a cached piece would cost.
func cached_chrome() -> Control:
	var vp := SubViewport.new()
	vp.size = Vector2i(200, 400)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.2, 0.8)
	sb.border_color = Color(0.5, 0.5, 0.5)
	sb.set_border_width_all(1)
	for i in 10:
		var p := panel(sb, Vector2(5, 5 + i * 38), Vector2(180, 30))
		p.add_child(label("BONE WARD", DmUi.font("body"), 12, Vector2(10, 5), true))
		vp.add_child(p)
	var holder := Control.new()
	holder.add_child(vp)
	var tr := TextureRect.new()
	tr.texture = vp.get_texture()
	tr.position = Vector2(10, 10)
	holder.add_child(tr)
	return holder


# ---- fidelity: the replacements against the originals ------------------------------------------------------------------------------------

## The stock drawing and its replacement drawn 1:1 into two transparent SubViewports, compared pixel by pixel on grey: mean and largest per-channel difference (0 to 1) and how
## many pixels differ by more than 8 %. Panels (9-patch of the atlas against StyleBoxFlat), outlines (rectangles against draw_rect), discs and rings (meshes against draw_circle
## and draw_arc), a gradient bar (a strip of the atlas against a polygon with vertex colours) and an icon (the atlas copy against the file's own texture).
func fidelity() -> void:
	if headless:
		return
	var np := func(bg: Color, edge: Color, w: Vector4, r: int) -> Array:
		var flat := DmHudKit.style(bg, edge, w, Vector4(0, 0, 0, 0), r)
		var nine := DmHudKit.plate(bg, edge, w, Vector4(0, 0, 0, 0), r)
		return [flat, nine]
	var cases := [
		["panel: translucent fill, 1 px border, square", np.call(Color(0.0275, 0.0235, 0.0392, 0.55), DmUi.BORDER, Vector4(1, 1, 1, 1), 0)],
		["panel: opaque fill, strong border, radius 2 (the hotbar's plate)", np.call(Color(0.058, 0.04, 0.075, 0.95), DmUi.BORDER_STRONG, Vector4(1, 1, 1, 1), 2)],
		["panel: radius 3 plate", np.call(DmUi.PANEL, DmUi.BORDER, Vector4(1, 1, 1, 1), 3)],
		["panel: 3 px left rule (omen, ward)", np.call(Color(0.0275, 0.0235, 0.0392, 0.55), DmUi.SPELL_300, Vector4(3, 0, 0, 0), 0)],
		["panel: 2 px bottom rule (depth)", np.call(Color(0.0275, 0.0235, 0.0392, 0.5), DmUi.BORDER_STRONG, Vector4(0, 0, 0, 2), 0)],
	]
	for c in cases:
		var pair: Array = c[1]
		await compare(c[0], Vector2i(140, 50), func(cv: Control) -> void: pair[0].draw(cv.get_canvas_item(), Rect2(10, 8, 100, 24)),
			func(cv: Control) -> void: pair[1].draw(cv.get_canvas_item(), Rect2(10, 8, 100, 24)))
		await compare(c[0] + " (a small one)", Vector2i(60, 40), func(cv: Control) -> void: pair[0].draw(cv.get_canvas_item(), Rect2(8.0, 8.0, 20, 20)),
			func(cv: Control) -> void: pair[1].draw(cv.get_canvas_item(), Rect2(8.0, 8.0, 20, 20)))
	for w in [1.0, 2.0]:
		await compare("rect outline width %d: draw_rect against four rectangles" % int(w), Vector2i(120, 60), func(cv: Control) -> void: cv.draw_rect(Rect2(10, 10, 60, 30), Color(1, 0.2, 0.2, 0.8), false, w),
			func(cv: Control) -> void: DmHudKit.outline(cv, Rect2(10, 10, 60, 30), Color(1, 0.2, 0.2, 0.8), w))
	for r in [1.8, 3.0, 5.0, 59.0]:
		await compare("disc radius %.1f: draw_circle against the 64 triangle mesh" % r, Vector2i(140, 140), func(cv: Control) -> void: cv.draw_circle(Vector2(70, 70), r, Color(0.8, 0.7, 0.9, 0.6)),
			func(cv: Control) -> void:
				var mesh := DmHudMesh.new()
				mesh.disc(Vector2(70, 70), r, Color(0.8, 0.7, 0.9, 0.6))
				mesh.submit(cv))
	await compare("ring: draw_arc width 4 antialiased against a mesh ring", Vector2i(140, 140), func(cv: Control) -> void: cv.draw_arc(Vector2(70, 70), 54.0, 0.0, TAU, 48, Color(0.85, 0.8, 0.7, 0.6), 4.0, true),
		func(cv: Control) -> void:
			var mesh := DmHudMesh.new()
			mesh.ring(Vector2(70, 70), 52.0, 56.0, Color(0.85, 0.8, 0.7, 0.6), 48)
			mesh.submit(cv))
	await compare("bar: polygon with vertex colours against the atlas gradient", Vector2i(220, 24), func(cv: Control) -> void:
		cv.draw_polygon(PackedVector2Array([Vector2(10, 6), Vector2(200, 6), Vector2(200, 16), Vector2(10, 16)]), PackedColorArray([Color("4a1f3a"), Color("8a3a6c"), Color("8a3a6c"), Color("4a1f3a")])),
		func(cv: Control) -> void: DmHudKit.gradient_rect(cv, Rect2(10, 6, 190, 10), Color("4a1f3a"), Color("8a3a6c")))
	var path := "res://assets/game/art/abilities/necro-marrow-spear.webp"
	if ResourceLoader.exists(path):
		var orig: Texture2D = load(path)
		var packed: Texture2D = DmHudAtlas.icon(path, 160)
		await compare("icon at 62 px: the file's texture against the atlas copy (160 px, Lanczos)", Vector2i(80, 80), func(cv: Control) -> void: cv.draw_texture_rect(orig, Rect2(9, 9, 62, 62), false),
			func(cv: Control) -> void: cv.draw_texture_rect(packed, Rect2(9, 9, 62, 62), false))


## Draws `a` and `b` (Callables taking the Control to draw on) into SubViewports of `size` and reports how far apart the pictures are.
func compare(name: String, size: Vector2i, a: Callable, b: Callable) -> void:
	if late():
		return
	var ia := await render_image(size, a)
	var ib := await render_image(size, b)
	var sum := 0.0
	var worst := 0.0
	var bad := 0
	var px := size.x * size.y
	for y in size.y:
		for x in size.x:
			var ca := ia.get_pixel(x, y)
			var cb := ib.get_pixel(x, y)
			var da := Color(ca.r * ca.a + 0.5 * (1.0 - ca.a), ca.g * ca.a + 0.5 * (1.0 - ca.a), ca.b * ca.a + 0.5 * (1.0 - ca.a))
			var db := Color(cb.r * cb.a + 0.5 * (1.0 - cb.a), cb.g * cb.a + 0.5 * (1.0 - cb.a), cb.b * cb.a + 0.5 * (1.0 - cb.a))
			var d := maxf(absf(da.r - db.r), maxf(absf(da.g - db.g), absf(da.b - db.b)))
			sum += d
			worst = maxf(worst, d)
			if d > 0.08:
				bad += 1
	emit({"event": "fidelity", "name": name, "mean": snappedf(sum / px, 0.00001), "max": snappedf(worst, 0.001), "over_8pct": bad, "pixels": px,
		"drawn_a": drawn_pixels(ia), "drawn_b": drawn_pixels(ib)})


## Pixels with any coverage (a picture of nothing would "match" anything).
func drawn_pixels(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.02:
				n += 1
	return n


func render_image(size: Vector2i, draw: Callable) -> Image:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.add_child(Painter.new(draw, Vector2(size)))
	root.add_child(vp)
	await next_frame()
	await next_frame()
	var img := vp.get_texture().get_image()
	vp.queue_free()
	if img == null or img.is_empty():
		return Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.convert(Image.FORMAT_RGBA8)
	return img


# ---- the game stage -----------------------------------------------------------------------------------------------------------------------

func game_stage(args: PackedStringArray) -> void:
	if late():
		return
	var use_3d := "--3d" in args
	root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.disable_3d = not use_3d   # the HUD's draw calls do not depend on the scene behind it; without it no 3D pipeline is compiled (lavapipe takes seconds for each)
	var idle := Camera3D.new()
	root.add_child(idle)
	idle.current = true
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 20)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["graves"], "name": "tester", "hud": true, "waves": false, "audio": false, "seed": 20261016})
	idle.queue_free()
	hud_layer = HudShim.new(g) if g.ui != null else null
	emit({"event": "game_started", "ms": g.load_ms, "hud": hud_layer != null, "scene_3d": use_3d})
	if hud_layer == null:
		return
	bd = hud_layer.hud
	await setup_fight()
	for i in 40:
		spam()
		await physics_frame
	RenderingServer.render_loop_enabled = true
	await frames(6, spam)
	var cpu := cpu_cost()
	emit({"event": "cpu", "refresh_us": cpu[0], "build_us": cpu[1], "apply_us": cpu[2], "per_frame_us_at_60": cpu[0] * 20.0 / 60.0,
		"live_refresh_us": float(hud_layer.refresh_us) / maxf(hud_layer.refreshes, 1.0), "live_refreshes": hud_layer.refreshes})
	await official("game")        # the HUD as the game scene shows it
	show_everything()             # every piece on, fed
	await frames(4, spam)
	await official("full")
	if shot_path != "" and not headless:
		await next_frame()
		var img := root.get_viewport().get_texture().get_image()
		img.save_png(shot_path)
		emit({"event": "shot", "path": shot_path, "size": str(img.get_size())})
	await extra_phases(args)
	if "--no-breakdown" in args or late():
		return
	root.disable_3d = true
	await frames(2, spam)
	await breakdown()


## What else this run was asked for, after the numbers that matter are written: the batching cases, the fidelity of the replacements (each draws on its own, so the HUD is hidden).
func extra_phases(args: PackedStringArray) -> void:
	hud_layer.visible = false
	if "--fidelity" in args:
		await fidelity()
	if "--micro" in args:
		await micro_setup()
		await micro_batching()
		if "--micro-all" in args:
			await micro()
		micro_teardown()
	hud_layer.visible = true


## The Full Party-like fight and the HUD's state in it: casts on cooldown, a target with statuses, toasts, a banner.
func setup_fight() -> void:
	full_party()
	for i in 20:
		await physics_frame
	var b := g.local_body()
	var caster := b.get_node("Rites") as DmRiteCaster
	for rite in ["marrow_spear", "miasma", "exhume"]:
		caster.request_cast(rite, b.position + Vector3(0, 0, -6), -1)
	var elite := first_elite()
	var target_id := elite if elite != 0 else int(g.core_host.core.enemy_ids()[0])
	for st in ["chill", "fracture", "withered", "bleed"]:
		g.core_host.apply_status(target_id, st, b.core_id, 3.0 if st in ["fracture", "withered"] else 1.0, 60.0)
	hud_layer._on_hotbar(0, Vector3.ZERO, target_id)
	hud_layer.hud.toast("The dead answer you more readily", "good")
	hud_layer.hud.toast("A crypt cracks open in The Hollow Graves", "")
	hud_layer.hud.banner("The Hollow Graves", "Where the Covenant buries what it cannot keep", 600000)


## 72 enemies in a ring, 4 heroes with 8 thralls each (the local hero's are his own), nobody able to hurt anybody.
func full_party() -> void:
	var host := g.core_host
	var core := host.core
	var b := g.local_body()
	var heroes := [b.core_id]
	for h in 3:
		var id: int = core.add_external(0, 0.4, 1.0)
		core.set_external(id, Vector2(b.position.x + 4.0 * (h + 1), b.position.z), true)
		host.view.set_owner_legion(id, LEGIONS[h + 1])
		heroes.append(id)
	var kinds := ["warrior", "warrior", "warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage"]
	for h in 4:
		for k in 8:
			var base: Array = THRALL_BASE[kinds[k]]
			var at := Vector2(b.position.x + 4.0 * h + float(k) - 3.0, b.position.z + 3.0)
			core.raise_thrall({"kind": kinds[k], "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": base[1], "range": base[0], "speed": base[2], "empowered": false,
				"champion": h == 1 and k == 0, "allyHeal": 0.0}, heroes[h], at, 0.0, 20.0)
	var defs := ["robber", "robber", "hound", "ghoul", "wraith", "robber", "hound", "robber"]
	for e in 72:
		var a := float(e) / 72.0 * TAU
		var p := Vector2(b.position.x, b.position.z) + Vector2(cos(a), sin(a)) * (10.0 + float(e % 5) * 1.5)
		host.spawn_enemy(defs[e % defs.size()], Vector3(p.x, 0.0, p.y), 1, 1000.0, 0.0, e % 24 == 5, "graves", false)


func first_elite() -> int:
	for id in g.core_host.core.enemy_ids():
		if g.ui_host.is_elite(id):
			return id
	return 0


## Keeps the floating numbers at their caps: a handful of every kind per frame, the caps (counted in game time) decide how many live.
func spam() -> void:
	fps_now_ms += 1000.0 / 60.0
	var b := g.local_body()
	for i in 6:
		var kind: String = ["hit", "hit", "crit", "dot", "thrall", "hit"][i]
		spam_n += 1
		var p := b.position + Vector3(float(spam_n % 11) - 5.0, 1.6, -4.0 + float(spam_n % 7))
		hud_layer.float_text(p, str(100 + spam_n % 900), kind, null, fps_now_ms)


## Everything the full HUD can show at once: the panels the game scene hides, and the feeds of the systems that are not in it yet (tests/hud_feeds.gd).
func show_everything() -> void:
	var h := hud_layer.hud
	h.menu_flow.visible = true
	h.chat_col.visible = true
	h.chat_line("[Helix] over here")
	h.chat_line("You found Bone Dust")
	hud_layer.feeds = HudFeeds.full()
	hud_layer.refresh()


## HUD hidden, shown, hidden, shown (the noise between two equal frames shows), for one state.
func official(state: String) -> void:
	var res := {}
	for step in ["off", "on", "off", "on"]:
		hud_layer.visible = step == "on"
		var r := await frames(3, spam)
		res[step + str(res.size())] = r
	var on: Dictionary = res["on3"]
	var off: Dictionary = res["off2"]
	var canvas_hud := int(on["canvas"]) - int(off["canvas"])
	var total_hud := int(on["total"]) - int(off["total"])
	emit({"event": "official", "state": state, "hidden": off, "shown": on, "hidden_first": res["off0"], "shown_first": res["on1"],
		"hud_total": total_hud, "hud_canvas": canvas_hud, "budget": BUDGET, "counted": int(on["total"]) > 0, "within": int(on["total"]) > 0 and maxi(total_hud, canvas_hud) <= BUDGET})
	hud_layer.visible = true


## Mean cost of one refresh (view-model build + apply) in microseconds, over 200 refreshes of the live scene.
func cpu_cost() -> Array:
	var vm := hud_layer.vm
	var n := 200
	var tb := 0
	var ta := 0
	for i in n:
		var t1 := Time.get_ticks_usec()
		var d := vm.build()
		var t2 := Time.get_ticks_usec()
		hud_layer.hud.apply(d)
		var t3 := Time.get_ticks_usec()
		tb += t2 - t1
		ta += t3 - t2
	return [float(tb + ta) / n, float(tb) / n, float(ta) / n]


# ---- where the draw calls go: each piece alone -----------------------------------------------------------------------------------------------

func breakdown() -> void:
	var h := bd
	var base := await solo(null)
	emit({"event": "breakdown_base", "canvas": base["canvas"], "total": base["total"]})
	var tops: Array[Node] = []
	for c in h.get_children():
		if c != h.safe:
			tops.append(c)
	for c in h.safe.get_children():
		tops.append(c)
	for c in tops:
		if late():
			return
		await profile(c, h, 0, int(base["canvas"]))


## Draw calls of `node` shown alone (every other node of the HUD hidden): the counter minus the empty HUD's. Recurses into the children of the costly ones.
func profile(node: Node, hud_root: Node, depth: int, base: int) -> void:
	if not node is CanvasItem or (node as CanvasItem).visible == false:
		return
	var r := await solo(node)
	var cost := int(r["canvas"]) - base
	emit({"event": "piece", "path": str(hud_root.get_path_to(node)), "class": node.get_class(), "script": node.get_script().get_global_name() if node.get_script() != null else "", "depth": depth, "draws": cost})
	if cost >= 5 and depth < 5:
		for c in node.get_children():
			if late():
				return
			await profile(c, hud_root, depth + 1, base)


var _hidden: Array = []

## Shows only `node` (and its parents): hides its siblings and theirs up the chain, waits one frame, returns the counters; restores everything.
func solo(node: Node) -> Dictionary:
	var h := bd
	_hidden.clear()
	var n: Node = node
	if node == null:
		for c in h.get_children():
			hide_it(c)
		for c in h.safe.get_children():
			hide_it(c)
	else:
		while n != h and n != null:
			for s in n.get_parent().get_children():
				if s != n:
					hide_it(s)
			n = n.get_parent()
	var r := await frames(1)
	for c in _hidden:
		c.visible = true
	_hidden.clear()
	return r


func hide_it(c: Node) -> void:
	if c is CanvasItem and (c as CanvasItem).visible:
		(c as CanvasItem).visible = false
		_hidden.append(c)
