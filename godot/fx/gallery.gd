extends Node3D
## DmFx gallery: every Binbun effect (paged, same order/layout as the web's DEV `__cwDebug.vfxGallery(page)`) plus a page of the
## procedural Effects.ts primitives. Interactive: `godot --path godot res://fx/gallery.tscn` (Left/Right = page, R = replay).
## Capture: `fx/shoot.sh <page> [out.png] [t1,t2,...]` (fixed 30 fps so frames are deterministic).
## Args after `--`: --page=N (0-based) --per=16 --out=file.png --t=0.6[,1.2] --ids=a,b --kind=binbun|prims --gain=1.0

const SPACING := 4.2

var _fx: DmFxRuntime
var _cam: Camera3D
var _page := 0
var _per := 16
var _kind := "binbun"
var _ids: Array = []
var _cells: Array = []
var _out := ""
var _times: Array[float] = [0.6]
var _label_root: Node3D
var _frame := 0
var _gain := 1.0
var _glow := 0.8
var _spacing := SPACING


func _args() -> Dictionary:
	var d := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			d[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return d


func _ready() -> void:
	var args := _args()
	_page = int(args.get("page", 0))
	_per = int(args.get("per", 16))
	_kind = String(args.get("kind", "binbun"))
	_out = String(args.get("out", ""))
	_gain = float(args.get("gain", 1.0))
	_glow = float(args.get("glow", 0.8))
	_spacing = float(args.get("spacing", SPACING))
	if args.has("t"):
		_times.clear()
		for s in String(args["t"]).split(","):
			_times.append(float(s))
	_build_world()
	_fx = DmFxRuntime.new()
	add_child(_fx)
	_fx.binbun.gain = _gain
	if args.has("ids"):
		_ids = String(args["ids"]).split(",")
	elif _kind == "binbun":
		var all: Array = DmFxData.catalog("effects")
		_ids = all.slice(_page * _per, (_page + 1) * _per)
	if _kind == "prims":
		_frame_camera(8.0)
		await get_tree().process_frame
		_spawn_prims()
	else:
		_spawn_page()
	if _out != "":
		_capture.call_deferred()


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("0b0810")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("2a2433")
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = _glow > 0.0
	env.glow_intensity = _glow
	env.glow_bloom = 0.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("1b1722")
	fm.roughness = 1.0
	floor_mesh.material_override = fm
	floor_mesh.position.y = -0.02
	add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 0.5
	sun.light_color = Color("c9b8e8")
	add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 45.0
	add_child(_cam)
	_label_root = Node3D.new()
	add_child(_label_root)


func _label(text: String, pos: Vector3) -> void:
	var lab := Label3D.new()
	lab.text = text
	lab.font_size = 36
	lab.pixel_size = 0.0075
	lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lab.no_depth_test = true
	lab.modulate = Color("f3e8d2")
	lab.outline_size = 8
	lab.position = pos
	_label_root.add_child(lab)


## The procedural Effects.ts primitives, one per cell (4 columns), each with a SPELL_FX colour.
func _spawn_prims() -> void:
	var fx := _fx
	var X := func(i: int) -> float: return (float(i % 5) - 2.0) * 3.4
	var Z := func(i: int) -> float: return (float(i / 5) - 1.0) * 3.4
	var items := ["decal disc", "decal ring", "decal sigil", "decal cone", "decal cracks", "emit burst", "emit_smoke", "flash+glow", "beam", "orbit",
		"spike_ring", "spike_line", "grave_hands", "bone_orbit", "projectile", "danger ring", "settling disc", "skull_ring", "motifs", "crescent"]
	for i in items.size():
		var x: float = X.call(i)
		var z: float = Z.call(i)
		_label(items[i], Vector3(x, 0.02, z + 1.5))
		var c := DmFxData.spell("exhume", "spirit")
		match items[i]:
			"decal disc": fx.decal({"tex": "disc", "color": DmFxData.spell("litany", "core"), "x": x, "z": z, "r": 1.2, "duration": 30.0, "growFrom": 0.5})
			"decal ring": fx.decal({"tex": "ring", "color": DmFxData.spell("miasma", "rot"), "x": x, "z": z, "r": 1.2, "duration": 30.0})
			"decal sigil": fx.decal({"tex": "sigil", "color": DmFxData.spell("souls", "jade"), "x": x, "z": z, "r": 1.3, "duration": 30.0, "spin": 0.4})
			"decal cone": fx.decal({"tex": "cone", "color": DmFxData.spell("frost", "frost"), "x": x, "z": z, "r": 1.6, "duration": 30.0, "anchor": -1.0, "rot": 0.6})
			"decal cracks": fx.decal({"tex": "cracks", "color": DmFxData.spell("detonate", "ember"), "x": x, "z": z, "r": 1.3, "duration": 30.0})
			"emit burst": fx.emit({"x": x, "y": 0.6, "z": z, "count": 120, "color": DmFxData.spell("detonate", "hot"), "spread": 0.3, "speed": 2.0, "up": 1.5, "life": 3.0, "size": 0.25})
			"emit_smoke": fx.emit_smoke({"x": x, "y": 0.4, "z": z, "count": 40, "color": DmFxData.spell("detonate", "smoke"), "spread": 0.4, "speed": 0.6, "up": 0.8, "life": 3.0, "size": 0.9})
			"flash+glow": fx.flash({"x": x, "y": 1.0, "z": z, "color": DmFxData.spell("litany", "hot"), "size": 2.0, "duration": 30.0})
			"beam": fx.beam(Vector3(x - 1.2, 0.8, z), func(): return Vector3(x + 1.2, 1.4, z), DmFxData.spell("exhume", "beam"), 0.12, 30.0)
			"orbit": fx.orbit({"tex": "glow", "color": c, "count": 6, "radius": 1.0, "y": 0.8, "size": 0.35, "duration": 30.0, "speed": 2.0, "follow": func(): return Vector3(x, 0, z)})
			"spike_ring": fx.spike_ring(x, z, 1.2, 12, 30.0)
			"spike_line": fx.spike_line(x - 1.2, z, 1.0, 0.0, 3.0, 1.0, false)
			"grave_hands": fx.grave_hands(x, z, 1.0, 5, 30.0)
			"bone_orbit": fx.bone_orbit({"count": 9, "radius": 1.0, "y": 0.8, "size": 0.35, "duration": 30.0, "speed": 2.0, "follow": func(): return Vector3(x, 0, z), "fallbackTex": "glow", "fallbackColor": c})
			"projectile": fx.projectile({"from": Vector3(x - 1.2, 0.8, z), "to": func(): return Vector3(x + 1.2, 0.8, z), "speed": 1.0, "color": DmFxData.spell("needle", "core"), "kind": "needle"})
			"danger ring": fx.danger(func(): fx.decal({"tex": "ring", "color": 0xff3030, "x": x, "z": z, "r": 1.3, "duration": 30.0}))
			"settling disc": fx.decal({"tex": "disc", "color": DmFxData.spell("bloom", "petal"), "x": x, "z": z, "r": 1.3, "duration": 30.0})
			"skull_ring": fx.motifs.skull_ring(x, z, 1.0, DmFxData.spell("skull", "jade"), {"n": 6})
			"motifs": fx.motifs.bone_splinters(x, 1.0, z, {"n": 12})
			"crescent": fx.decal({"tex": "crescent", "color": DmFxData.spell("rend", "jade"), "x": x, "z": z, "r": 1.2, "duration": 30.0})


func _frame_camera(extent: float) -> void:
	# Looking down at ~55 degrees, like the game's camera, centred on the grid.
	var dist := extent * 1.7 + 6.0
	_cam.position = Vector3(0, dist * 0.82, dist * 0.57)
	_cam.look_at(Vector3(0, 0.3, 0.3), Vector3.UP)


func _clear_cells() -> void:
	for c in _cells:
		if c["handle"] != null:
			c["handle"].kill()
		if c["label"] != null:
			c["label"].queue_free()
	_cells.clear()
	_fx.binbun.clear()


func _spawn_page() -> void:
	_clear_cells()
	var n := _ids.size()
	var cols := int(ceil(sqrt(float(max(n, 1)))))
	var rows := int(ceil(float(n) / float(cols)))
	_frame_camera(maxf(cols, rows) * _spacing * 0.5)
	for i in n:
		var x := (float(i % cols) - float(cols - 1) / 2.0) * _spacing
		var z := (float(i / cols) - float(rows - 1) / 2.0) * _spacing
		var lab := Label3D.new()
		lab.text = String(_ids[i])
		lab.font_size = 36
		lab.pixel_size = 0.0075
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.no_depth_test = true
		lab.modulate = Color("f3e8d2")
		lab.outline_size = 8
		lab.position = Vector3(x, 0.02, z + 1.4)
		_label_root.add_child(lab)
		_cells.append({"id": _ids[i], "pos": Vector3(x, 0.05, z), "handle": null, "label": lab, "timer": 0.0})
	_play_all()
	_frame = 0


func _play_all() -> void:
	for c in _cells:
		_play(c)


func _play(c: Dictionary) -> void:
	if c["handle"] != null:
		c["handle"].kill()
	# The gallery spawns raw (no preset), at y=0.05 with the file's own colours, exactly like the web gallery.
	c["handle"] = _fx.play(c["id"], c["pos"], {"raw": true, "y": 0.05, "once": DmFxData.is_impact(c["id"])})
	c["timer"] = 0.0


func _process(dt: float) -> void:
	_frame += 1
	if _out != "":
		return
	for c in _cells:
		c["timer"] += dt
		if not DmFxData.is_looper(c["id"]) and c["timer"] > 2.4:
			_play(c)


func _unhandled_key_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed:
		if e.keycode == KEY_RIGHT:
			_page += 1
			_ids = DmFxData.catalog("effects").slice(_page * _per, (_page + 1) * _per)
			_spawn_page()
		elif e.keycode == KEY_LEFT and _page > 0:
			_page -= 1
			_ids = DmFxData.catalog("effects").slice(_page * _per, (_page + 1) * _per)
			_spawn_page()
		elif e.keycode == KEY_R:
			_play_all()


func _capture() -> void:
	# Fixed 30 fps (set by shoot.sh): frame N = N/30 s of simulation.
	var shots := 0
	var last := 0
	for t in _times:
		var target := int(round(t * 30.0))
		while _frame < target:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := _out
		if _times.size() > 1:
			path = _out.get_basename() + "_t%d.png" % int(round(t * 100.0))
		img.save_png(path)
		print("saved ", path, " ", img.get_size(), " frame ", _frame)
		shots += 1
		last = _frame
	get_tree().quit()
