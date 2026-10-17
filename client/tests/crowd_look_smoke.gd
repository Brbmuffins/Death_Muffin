extends SceneTree
## The crowd thrall next to today's: one rendered frame with the same cast of thralls drawn side by side, in two rows. Back row, the look: today's skinned creature (DmCreature,
## built the way DmEntityViews._make_thrall builds it: the tint, the emissive, the friend rim, the hand props), the crowd now, and the crowd as it was (`--before-shader=` an
## older crowd_vat.gdshader). Front row, the lighting alone: the same without emissive and rim (today's `emissive_intensity` 0 and rim strength 0, the crowd's palettes emptied),
## and the crowd now without its metallic factor. (`--rows=look` or `--rows=bare` draws one row.) The world's own lighting (DmWorldBuilder: the Hollow Graves' ambient, the moon,
## the violet rim light, ACES, High's bloom and ambient occlusion) on a flat unshaded ground, so the thralls' pixels are told from the ground's. Prints the mean colour of every
## column's pixels (sRGB, as the screenshot has them) and its distance from today's.
## Run on the VPS (one rendered run at a time, Compatibility on llvmpipe):
##   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1600x900x24" timeout 90 \
##     /home/ubuntu/tools/godot/godot --rendering-method gl_compatibility --rendering-driver opengl3 --resolution 1600x900 --path client \
##     --script res://tests/crowd_look_smoke.gd -- --out=/abs/path/crowd_look.png [--before-shader=/abs/path/old.gdshader] [--rows=look]
## Forward+ (the renderer the rebuild plays on) on the software Vulkan driver (about two minutes), the same arguments after:
##   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json ... --rendering-method forward_plus --rendering-driver vulkan --resolution 1280x720 ...
## Needs the thralls baked: bash client/tools/bake_crowd.sh skeleton_thrall thrall_legionnaire bone_hound carrion_sac bone_colossus wraith_thrall
##   thrall_legionnaire+warrior thrall_legionnaire+shieldbearer skeleton_thrall+warrior skeleton_thrall+shieldbearer skeleton_thrall+archer skeleton_thrall+bonemage

const DT := 1.0 / 60.0
const CHAMPION_SCALE := 1.35
## The columns: where each is drawn (x, z of its middle) and what it is. `bare`: no emissive, no rim; `nometal`: the crowd without its metallic factor; `old`: the older shader;
## `debug`: the shader's own values drawn as colours instead of the lit look (`flash`: red the hit flash, green the glow's strength, blue the rim's; `fres`: the rim's mask; `normal`:
## the view-space normal).
const COLUMNS := {
	"today": {"at": Vector2(-9.9, -4.4), "crowd": false, "row": "look"},
	"after": {"at": Vector2(-3.3, -4.4), "crowd": true, "row": "look"},
	"before": {"at": Vector2(3.3, -4.4), "crowd": true, "old": true, "row": "look"},
	"debug_flash": {"at": Vector2(9.9, -4.4), "crowd": true, "debug": "flash", "row": "debug"},
	"today_bare": {"at": Vector2(-9.9, 4.4), "crowd": false, "bare": true, "row": "bare"},
	"after_bare": {"at": Vector2(-3.3, 4.4), "crowd": true, "bare": true, "row": "bare"},
	"nometal_bare": {"at": Vector2(3.3, 4.4), "crowd": true, "bare": true, "nometal": true, "row": "bare"},
	"debug_fres": {"at": Vector2(9.9, 4.4), "crowd": true, "debug": "fres", "row": "debug"},
}
## The cast of one column. `o`: whose thrall ("A": this player's, Gravecaller legion; "B": another player's, no legion).
const CAST := [
	{"k": "warrior", "o": "A"}, {"k": "shieldbearer", "o": "A"}, {"k": "wraith", "o": "A"},
	{"k": "bonemage", "o": "B"}, {"k": "hound", "o": "B", "champion": true}, {"k": "plaguebearer", "o": "B"}, {"k": "colossus", "o": "B"},
]
## Where the two owners stand; the thralls rise beside them and walk to their formation spots.
const HERO := {"A": Vector2(-1.2, 0.4), "B": Vector2(1.2, 0.4)}
## Core ticks until the thralls have risen (60) and settled into their formation.
const SETTLE_TICKS := 300
## godot/game/dm_entity_views.gd LEGION, THRALL_SLUG, THRALL_LOOK (the oracle: kept as today's, not read from crowd_looks.json).
const LEGION := {
	"gravecaller": {"slug": "thrall_legionnaire", "tint": 0xffffff, "emissive": 0x6a3fc0, "glow": 0.16, "armed": true},
	"mourner": {"slug": "wraith_thrall"},
}
const SLUG := {"warrior": "skeleton_thrall", "shieldbearer": "skeleton_thrall", "hound": "bone_hound", "wraith": "skeleton_thrall", "archer": "skeleton_thrall",
	"bonemage": "skeleton_thrall", "plaguebearer": "carrion_sac", "colossus": "bone_colossus"}
const LOOK := {
	"archer": {"tint": 0xf2e6cc, "emissive": 0x6b4a1f, "glow": 0.25},
	"bonemage": {"tint": 0xe6dccb, "emissive": 0xb07a2a, "glow": 0.35},
	"plaguebearer": {"tint": 0xb9c48a, "emissive": 0x5a6a18, "glow": 0.35, "scale": 0.8},
	"colossus": {"tint": 0xffffff, "emissive": 0x1f8f86, "glow": 0.1},
}

var _out := "/tmp/crowd_look.png"
var _before_shader := ""
var _rows := ["look", "bare", "debug"]
var _creatures: Array = []


func _initialize() -> void:
	await process_frame
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--before-shader="):
			_before_shader = a.substr(16)
		elif a.begins_with("--rows="):
			_rows = a.substr(7).split(",")
	var godot_dir := ProjectSettings.globalize_path("res://").path_join("../godot")
	var world := Node3D.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = 50.0
	cam.current = true
	world.add_child(cam)
	cam.look_at_from_position(Vector3(0, 27.0, 19.5), Vector3(0, 0.4, 0.4))
	var wb := DmWorldBuilder.new()
	world.add_child(wb)
	wb.world = DmData.world()
	wb.occlusion_enabled = false
	wb._make_environment()
	wb.set_area("graves")
	DmGraphicsPreset.apply_environment(wb.env, "high")
	DmGraphicsPreset.apply_render(root, "high")
	wb.env.fog_enabled = false
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(120, 120)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.albedo_color = Color(0.16, 0.14, 0.2)
	ground.material_override = gm
	world.add_child(ground)
	print("renderer: ", RenderingServer.get_video_adapter_name(), " ", RenderingServer.get_current_rendering_method(), " ", root.size)

	var enemies: Dictionary = DmCoreData.json(godot_dir.path_join("data/content/enemies.json"))["ENEMIES"]
	var names: Array = []
	for n: String in COLUMNS:
		if _rows.has(COLUMNS[n].row) and not (COLUMNS[n].get("old", false) and _before_shader == ""):
			names.append(n)
	var crowds := {}
	for n: String in names:
		if COLUMNS[n].crowd:
			crowds[n] = _column(world, COLUMNS[n].at, godot_dir, enemies)
			if COLUMNS[n].get("old", false):
				_use_shader(crowds[n].view, FileAccess.get_file_as_string(_before_shader))
			elif COLUMNS[n].has("debug"):
				_use_shader(crowds[n].view, _debug_code(String(COLUMNS[n].debug)))
	if crowds.is_empty():
		printerr("FAIL crowd_look_smoke: no crowd column (bake the thralls, see the header)")
		quit(1)
		return
	var ref: Dictionary = crowds.values()[0]
	# The core steps until the thralls have risen and stand in their formation, then stops: they idle where they are, in the crowd's own sync and draw.
	for f in SETTLE_TICKS + 90:
		for col: Dictionary in crowds.values():
			if f < SETTLE_TICKS:
				col.core.step(DT)
			col.view.sync()
			col.core.take_events()
			col.view._process(DT)
	for n: String in names:
		if not COLUMNS[n].crowd:
			_build_today(world, n, ref)
	for f in 90:   # the props calibrate on the settled idle (DmCreature PROP_CALIBRATE_S)
		for c in _creatures:
			c.update(DT)
	var empty := PackedVector4Array()
	empty.resize(CrowdView.SLOTS)
	for n: String in crowds:   # the lighting alone: no glow, no rim (after the settling: the palettes only grow while new looks come into play)
		var v: CrowdView = crowds[n].view
		for m: ShaderMaterial in v._materials:
			if COLUMNS[n].get("bare", false):
				m.set_shader_parameter("glow_palette", empty)
				m.set_shader_parameter("rim_palette", empty)
			if COLUMNS[n].has("debug"):
				m.set_shader_parameter("use_normal", false)
			if COLUMNS[n].get("nometal", false):
				m.set_shader_parameter("metal_f", 0.0)
	if DisplayServer.get_name() == "headless":   # a dry run (no picture): what the looks came to
		var cr: RefCounted = ref.view.crowd
		print("glows ", cr.glow_palette().size(), " rims ", cr.rim_palette())
		for i in CAST.size():
			print(CAST[i].k, CAST[i].o, " ", cr.view_info(ref.ids[i]).pos)
		quit(0)
		return
	for f in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(_out)
	print("saved ", _out, " ", img.get_size())
	_measure(img, cam, names, ref)
	quit(0)


## A column of the crowd: its own core with the cast raised (this player's thralls and another's, rim and legion as the game gives them), drawn by its own CrowdView.
func _column(world: Node3D, at: Vector2, godot_dir: String, enemies: Dictionary) -> Dictionary:
	var core: RefCounted = ClassDB.instantiate("DmCore")
	core.set_seed(5)
	DmCoreData.load_all(core, godot_dir)
	core.set_wander(false)
	core.set_area_bounds(Vector2(-40, -40), Vector2(40, 40))
	var view := CrowdView.new()
	view.auto_sync = false
	view.position = Vector3(at.x, 0, at.y)
	world.add_child(view)
	view.setup(core, enemies, Vector2(-40, -40), Vector2(40, 40), {"assets_dir": CrowdBaker.default_assets_dir()})
	var owners := {}
	for o: String in ["A", "B"]:
		var id: int = core.add_external(0, 0.4, 1.0)
		core.set_external(id, HERO[o], true)
		view.set_owner_legion(id, "gravecaller" if o == "A" else "")
		view.set_owner_ally(id, o == "B")
		owners[o] = id
	var ids := []
	for c: Dictionary in CAST:
		ids.append(core.raise_thrall({"kind": c.k, "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6,
			"empowered": bool(c.get("empowered", false)), "champion": bool(c.get("champion", false)), "allyHeal": 0.0}, owners[c.o],
			HERO[c.o] + Vector2(cos(float(ids.size()) * 2.4), sin(float(ids.size()) * 2.4)) * 1.2, 0.0, 40.0))
	view.focus = Vector2(0, 0)
	return {"core": core, "view": view, "ids": ids}


## The crowd shader with a debug view appended to its fragment function: the values it works with drawn as the emission over a black body.
func _debug_code(mode: String) -> String:
	var code: String = (load(CrowdVatData.SHADER_PATH) as Shader).code
	var view := ""
	match mode:
		"flash":
			view = "ALBEDO = vec3(0.0); EMISSION = vec3(v_flash, clamp(v_glow.a, 0.0, 1.0), clamp(length(v_rim), 0.0, 1.0));"
		"fres":
			view = "ALBEDO = vec3(0.0); EMISSION = vec3(smoothstep(0.35, 0.95, 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0)));"
		"normal":
			view = "ALBEDO = vec3(0.0); EMISSION = normalize(NORMAL) * 0.5 + 0.5;"
	var end := code.rfind("}")
	return code.substr(0, end) + "\t" + view + "\n}\n"


## A shader's code on every material of a crowd (the spectral ones with SPECTRAL defined, as CrowdVatData.spectral_shader does).
func _use_shader(view: CrowdView, code: String) -> void:
	var plain := Shader.new()
	plain.code = code
	var ghost := Shader.new()
	ghost.code = code.replace("shader_type spatial;", "shader_type spatial;\n#define SPECTRAL")
	for m: ShaderMaterial in view._materials:
		m.shader = ghost if m.shader == CrowdVatData.spectral_shader() else plain


## Today's creatures where the crowd's thralls stand (the `ref` column's drawn spots) for the column `name`.
func _build_today(world: Node3D, name: String, ref: Dictionary) -> void:
	var at: Vector2 = COLUMNS[name].at
	for i in CAST.size():
		var info: Dictionary = ref.view.crowd.view_info(ref.ids[i])
		var cr := _today(CAST[i], bool(COLUMNS[name].get("bare", false)))
		world.add_child(cr.root)
		var p: Vector3 = info.pos
		cr.root.position = Vector3(at.x + p.x, p.y, at.y + p.z)
		cr.root.rotation.y = float(info.yaw)
		_creatures.append(cr)


## DmEntityViews._make_thrall for a thrall of this cast (no legion kit: today's host never provides one). `bare`: no emissive, no rim.
func _today(c: Dictionary, bare: bool) -> DmCreature:
	var kind: String = c.k
	var wraith := kind == "wraith"
	var champion := bool(c.get("champion", false))
	var look: Variant = LOOK.get(kind)
	var legion: Variant = null
	if look == null:
		legion = LEGION.get("mourner" if wraith else ("gravecaller" if c.o == "A" else ""))
	var slug: String = String(legion.slug) if legion != null else String(SLUG.get(kind, "skeleton_thrall"))
	var glow_base: float = 1.1 if wraith else (float(look.glow) if look != null else (float(legion.get("glow", 0.18)) if legion != null else 0.18)) + (0.22 if c.get("empowered", false) else 0.0)
	var spirit := int(DmFxData.data()["spell_fx"]["exhume"]["spirit"])
	var o := {
		"gear_tint": false,
		"tint": int(look.tint) if look != null else (int(legion.get("tint", 0xf4ecff)) if legion != null and legion.has("tint") else (0xb9c4ff if wraith else 0xf4ecff)),
		"emissive": int(look.emissive) if look != null else (int(legion.emissive) if legion != null and legion.has("emissive") else (0x8f9ed1 if wraith else 0x1f8f86)),
		"emissive_intensity": 0.0 if bare else glow_base + (0.35 if champion else 0.0),
		"spectral": wraith,
		"scale": (float(look.scale) if look != null and look.has("scale") else (1.1 if kind == "shieldbearer" else 1.0)) * (CHAMPION_SCALE if champion else 1.0),
		"rim": {"color": 0xd9a441 if champion else spirit, "strength": 0.0 if bare else (1.4 if champion else (0.6 if c.o == "B" else 0.9))},
	}
	var cr := DmCreature.new(slug, o)
	var armed: bool = legion == null or bool(legion.get("armed", false))
	if (kind == "warrior" or kind == "shieldbearer") and armed:
		cr.attach("R_Hand", DmGearProps.bone_sword(), Vector3(0, 1, 0.55), 0.6)
		cr.attach("L_Hand", DmGearProps.round_shield(0.5 if kind == "shieldbearer" else 0.32), Vector3(0, 1, 0), 0.5)
	elif kind == "archer":
		cr.attach("L_Hand", DmGearProps.bone_bow(), Vector3(0, 1, 0), 0.5)
	elif kind == "bonemage":
		cr.attach("R_Hand", DmGearProps.bone_staff(), Vector3(0, 1, 0.12), 0.15)
	return cr


# ----------------------------------------------------------------------------------------------------------------------------------- numbers

## The mean colour of the pixels of every column that are not the ground's (sRGB 0..255), and its distance from the column it is compared with: the looks with today's, the lighting
## alone with today's bare.
func _measure(img: Image, cam: Camera3D, names: Array, ref: Dictionary) -> void:
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var ground := [data[(8 * w + 8) * 3], data[(8 * w + 8) * 3 + 1], data[(8 * w + 8) * 3 + 2]]
	print("ground ", ground)
	var means := {}
	for n: String in names:
		var at: Vector2 = COLUMNS[n].at
		var a := cam.unproject_position(Vector3(at.x - 3.3, 0.0, at.y + 3.3))   # the box of the column: x and z within 3.3 m of its middle, up to 3.4 m high
		var b := cam.unproject_position(Vector3(at.x + 3.3, 3.4, at.y - 3.3))
		var x0 := clampi(int(minf(a.x, b.x)), 0, w - 1)
		var x1 := clampi(int(maxf(a.x, b.x)), 0, w - 1)
		var y0 := clampi(int(minf(a.y, b.y)), 0, h - 1)
		var y1 := clampi(int(maxf(a.y, b.y)), 0, h - 1)
		var sum := [0.0, 0.0, 0.0]
		var count := 0
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var o := (y * w + x) * 3
				if absi(data[o] - ground[0]) > 5 or absi(data[o + 1] - ground[1]) > 5 or absi(data[o + 2] - ground[2]) > 5:
					sum[0] += data[o]
					sum[1] += data[o + 1]
					sum[2] += data[o + 2]
					count += 1
		means[n] = [sum[0] / maxf(1.0, count), sum[1] / maxf(1.0, count), sum[2] / maxf(1.0, count), count]
	for n: String in names:
		var m: Array = means[n]
		var against := "today_bare" if COLUMNS[n].get("bare", false) else "today"
		var d := ""
		if n != against and means.has(against):
			var t: Array = means[against]
			d = "  distance from %s %.1f" % [against, sqrt(pow(m[0] - t[0], 2) + pow(m[1] - t[1], 2) + pow(m[2] - t[2], 2))]
		print("column %-13s mean (%5.1f %5.1f %5.1f) over %6d pixels%s" % [n, m[0], m[1], m[2], m[3], d])
	# every figure on its own: the pixels in a box around where it stands (the neighbours' edges may cross into it), the same in every column
	for n: String in names:
		var at: Vector2 = COLUMNS[n].at
		var line := "%-13s" % n
		for i in CAST.size():
			var p: Vector3 = ref.view.crowd.view_info(ref.ids[i]).pos
			var tall := 3.8 if CAST[i].k == "colossus" else (1.4 if CAST[i].k == "hound" else 2.2)
			var a := cam.unproject_position(Vector3(at.x + p.x - 0.8, 0.0, at.y + p.z + 0.5))
			var b := cam.unproject_position(Vector3(at.x + p.x + 0.8, tall, at.y + p.z - 0.5))
			var sum := [0.0, 0.0, 0.0]
			var count := 0
			for y in range(clampi(int(minf(a.y, b.y)), 0, h - 1), clampi(int(maxf(a.y, b.y)), 0, h - 1) + 1):
				for x in range(clampi(int(minf(a.x, b.x)), 0, w - 1), clampi(int(maxf(a.x, b.x)), 0, w - 1) + 1):
					var o := (y * w + x) * 3
					if absi(data[o] - ground[0]) > 5 or absi(data[o + 1] - ground[1]) > 5 or absi(data[o + 2] - ground[2]) > 5:
						sum[0] += data[o]
						sum[1] += data[o + 1]
						sum[2] += data[o + 2]
						count += 1
			line += "  %s%s (%3d %3d %3d)" % [String(CAST[i].k).substr(0, 4), String(CAST[i].o), roundi(sum[0] / maxf(1.0, count)), roundi(sum[1] / maxf(1.0, count)), roundi(sum[2] / maxf(1.0, count))]
		print(line)
