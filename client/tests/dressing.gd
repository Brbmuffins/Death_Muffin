extends SceneTree
## The world dressing on the area scenes (client/world_fx/README.md "World dressing", client/world_fx/), headless:
##   - the data: the stained-glass windows, the far silhouettes, the candle flames of the area data, the mist puffs, the weather profiles;
##   - attached to the world: a world built with lights has a dressing, one built without has none; its flames are one MultiMesh in each loaded area that has candles (the data's count),
##     its windows are under the area scene nearest to each, nothing of the stand-ins the converter used to leave (flame spheres, water planes, puddle quads) is in the tree, and
##     an area the world does not hold gets nothing;
##   - the area follows the hero by event: `enter_area` reaches the dressing, the weather cross-fades to it (its mesh built once and kept: a second visit is a cache hit) and the
##     water takes the area's moon and the Fen's palette; the Low preset thins the weather;
##   - the brazier fire: a particle's place, size and fade at any age equal the web's per-frame Euler step (the shader is that function in GLSL), the emission is the web's rate
##     (10 wisps and 1.5 embers a second a lit brazier in range), nothing is emitted out of range, and the ring stops drawing once its last particle has died;
##   - the mist: a step every STEP_SECONDS, the web's wrap rule (a puff more than 45 / 40 m from the focus goes to its far side at 44 / 39), the drift the web's;
##   - the candle groups: putting a candle group out writes its flames dark, lighting it brings them back;
##   - the earth beyond the walls: one quad over the field that spans every area, the converter's tint, a draw call;
##   - the Binbun scenes' own shaders: every one that reads its particle's COLOR in fragment() reads it converted from sRGB (as Compatibility gave it), the rest are untouched, and
##     every copy compiles;
##   - no objects pile up while the dressing runs (300 frames), and ZERO script errors or engine errors in the log.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/dressing.gd   (about 15 s)

class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var _data: Dictionary


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL dressing: " + what)


func _initialize() -> void:
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	DmSimData.ensure()
	_data = DmWfxData.get_data()
	_the_data()
	await _attached()
	_the_brazier_math()
	_the_brazier_emission()
	_the_ring()
	_the_mist()
	await _the_presets()
	_the_outside()
	_binbun_shaders()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s dressing %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


# ---------------------------------------------------------------- the data
func _the_data() -> void:
	var d := _data
	check(not d.is_empty(), "data/world_fx/fx.json is there")
	check(not d.windows.is_empty() and not d.silhouettes.is_empty(), "stained-glass windows and far silhouettes (%d, %d)" % [d.windows.size(), d.silhouettes.size()])
	var n := 0
	for k in d.flames:
		n += (d.flames[k].phase as Array).size()
	# the candle flames the fx data holds, area by area, are the candle props of world.json times the flames each prop's spec lights
	var world: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/slice/world.json"))
	var specs: Dictionary = world.propSpecs
	var want: Dictionary = {}
	for p in world.props:
		var fl := int((specs.get(String(p.prop), {}) as Dictionary).get("light", {}).get("flames", 0))
		if fl > 0:
			want[String(p.area)] = int(want.get(String(p.area), 0)) + fl
	var have: Dictionary = {}
	for k in d.flames:
		have[String(k)] = (d.flames[k].phase as Array).size()
	check(have == want and n > 0, "the candle flames in each area are the candle props' flames in world.json (%d over %d areas, %d expected over %d)" % [n, d.flames.size(), want.values().reduce(func(a, b): return a + b, 0), want.size()])
	check(int(d.mist.count) > 0 and (d.mist.pos as Array).size() == int(d.mist.count) * 3, "mist puffs: three numbers each (%d)" % int(d.mist.count))
	check(not d.atmosphere.profiles.is_empty(), "weather profiles (%d)" % d.atmosphere.profiles.size())


# ---------------------------------------------------------------- attached to the world
## {"area_<id>": window nodes} the dressing puts under the scenes of the `loaded` areas: each window of the data goes under the area nearest to it, when that area is loaded;
## a window is a pane and a shaft, two nodes.
func _windows_under(loaded: Array) -> Dictionary:
	var world: Dictionary = DmData.world()
	var out := {}
	for w in _data.windows:
		var id := DmWfxData.nearest_area(world.areas, world.order, float(w.x), float(w.z))
		if loaded.has(id):
			out["area_" + id] = int(out.get("area_" + id, 0)) + 2
	return out


func _stand_ins(w: Node) -> Array[String]:
	var found: Array[String] = []
	for n in w.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh is SphereMesh and absf((mi.mesh as SphereMesh).radius - 0.1) < 0.001:
			found.append(String(w.get_path_to(mi)))
		elif String(mi.name).begins_with("water_") or String(mi.name).begins_with("bog_") or String(mi.name).begins_with("pond_") or String(mi.name).begins_with("puddle_"):
			found.append(String(w.get_path_to(mi)))
	return found


func _attached() -> void:
	var bare := DmNextWorld.new()
	root.add_child(bare)
	bare.build(["graves"], false)
	check(bare.dressing == null, "a world built without lights has no dressing")
	bare.queue_free()
	var w := DmNextWorld.new()
	w.name = "World"
	root.add_child(w)
	w.build(["graves", "nave", "sanctum"], true)
	var dr := w.dressing
	check(dr != null and dr.get_parent() == w and dr.focus_node == w.focus, "a world built with lights has the dressing, following its focus")
	check(dr.area == "graves", "the dressing starts in the world's first area (%s)" % dr.area)
	check(_stand_ins(w).is_empty(), "no flame sphere, water plane or puddle quad in the scenes (%s)" % ", ".join(_stand_ins(w).slice(0, 3)))
	var want_areas: Array = []
	for id in ["graves", "nave", "sanctum"]:
		if _data.flames.has(id):
			want_areas.append(id)
	var keys: Array = dr.area_flames.keys()
	keys.sort()
	check(keys == want_areas, "flames in the loaded areas that have candles, and no other (%s)" % ", ".join(keys))
	var flames_ok := true
	for id: String in dr.area_flames:
		var mmi: MultiMeshInstance3D = dr.area_flames[id]
		flames_ok = flames_ok and mmi.multimesh.instance_count == (_data.flames[id].phase as Array).size() and mmi.get_parent() == w.area_node(id) and mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	check(flames_ok, "each flame MultiMesh holds the area's flames, stands under its area scene and casts no shadow")
	# the windows: a pane and a shaft each, under the scene of the area nearest to it (a window whose area is not loaded gets none)
	var under_want := _windows_under(["graves", "nave", "sanctum"])
	var under := {}
	for n in dr.window_nodes:
		under[String(n.get_parent().name)] = int(under.get(String(n.get_parent().name), 0)) + 1
	check(not under_want.is_empty() and under == under_want, "each window is under the scene of its nearest area, a pane and a shaft (%s)" % str(under))
	var only := DmNextWorld.new()
	root.add_child(only)
	only.build(["graves"], true)
	var graves_flames: Array = ["graves"] if _data.flames.has("graves") else []
	var only_nodes := 0
	for k in _windows_under(["graves"]):
		only_nodes += int(_windows_under(["graves"])[k])
	check(only.dressing.window_nodes.size() == only_nodes and only.dressing.area_flames.keys() == graves_flames, "a world of the Graves alone has its flames and only the windows nearest to it (%d nodes)" % only_nodes)
	only.queue_free()
	# the pieces and their draws: each is one object
	check(dr.silhouette_node != null and dr.mist_node != null and dr.atmosphere != null and dr.water != null and dr.brazier_fire != null, "silhouettes, mist, weather, water and brazier fire are all there")
	check(dr.water.mesh_instance.mesh.get_surface_count() == 1 and dr.silhouette_node.mesh.get_surface_count() == 1, "the water and the silhouettes are one mesh each")
	# the area by event
	w.enter_area("nave")
	check(dr.area == "nave" and not dr.water._high.get_shader_parameter("deep").is_equal_approx(DmWfxData.hex(0x02100e)), "enter_area reaches the dressing: the water has the Nave's palette")
	await frames(3)
	check(dr.atmosphere.area == "nave" and dr.atmosphere.count == dr.atmosphere.counts_for("nave") and dr.atmosphere._mi.mesh != null, "the weather is the Nave's (%d particles)" % dr.atmosphere.count)
	var nave_mesh: Mesh = dr.atmosphere._mi.mesh
	w.enter_area("graves")
	await frames(120)
	check(dr.atmosphere.area == "graves" and dr.atmosphere._mi.mesh != nave_mesh, "back in the Graves the weather is the Graves'")
	w.enter_area("nave")
	await frames(120)
	check(dr.atmosphere._mi.mesh == nave_mesh, "the Nave's weather is the mesh built the first time (kept, not built again)")
	w.enter_area("sanctum")
	var cache_before: int = dr.atmosphere._meshes.size()
	dr.atmosphere.warm("sanctum")
	check(dr.atmosphere._meshes.size() == cache_before + 1 or dr.atmosphere._meshes.has("sanctum|false"), "warm() builds an area's weather ahead of the visit")
	# the candle groups
	await frames(2)
	# a candle group the data names, in one of the loaded areas (the Sanctum's, today)
	var group_area := ""
	var group := ""
	for id: String in dr.area_flames:
		for gn in _data.flames[id].groups:
			if gn != null and group == "":
				group_area = id
				group = str(gn)
	check(group != "", "a loaded area has a named candle group (%s in %s)" % [group, group_area])
	var sanct: MultiMeshInstance3D = dr.area_flames[group_area]
	dr.set_candle_group(group, false)
	var lit: PackedFloat32Array = sanct.get_meta("lit")
	var groups: Array = sanct.get_meta("groups")
	var out_ok := true
	var n_out := 0
	var n_group := 0
	for i in groups.size():
		var in_group: bool = groups[i] != null and str(groups[i]) == group
		out_ok = out_ok and (lit[i] == 0.0) == in_group
		n_out += 1 if lit[i] == 0.0 else 0
		n_group += 1 if in_group else 0
	check(out_ok and n_out == n_group and n_group > 0, "putting the %s group of the %s out darkens its %d flames and no other (%d)" % [group, group_area, n_group, n_out])
	dr.set_candle_group(group, true)
	lit = sanct.get_meta("lit")
	var back := true
	for i in lit.size():
		back = back and lit[i] == 1.0
	check(back, "lighting them brings them back")
	# the feature switches
	dr.set_feature("mist", false)
	check(not dr.mist_node.visible, "a feature switched off is not drawn")
	dr.set_feature("mist", true)
	dr.set_enabled(false)
	check(not dr.silhouette_node.visible and not dr.is_processing(), "the master switch hides everything and stops the dressing")
	dr.set_enabled(true)
	check(dr.is_processing() and dr.silhouette_node.visible, "and brings it back")
	# nothing piles up. The count is the whole engine's: background work started earlier in the suite (loads, the weather's cross-fade) can still land in the first
	# frames on a slow machine (GitHub's 4-core runner: +31 once, 2026-10-18), so 300 frames settle first and the next 300 are measured: a pile-up grows in both.
	await frames(300)
	var objs0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	await frames(300)
	var objs1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	check(objs1 - objs0 <= 3, "no objects pile up in 300 frames of the dressing (%d -> %d)" % [objs0, objs1])
	w.queue_free()
	await frames(2)


# ---------------------------------------------------------------- the brazier fire's closed form against the web's per-frame step
## Effects.ts ParticleSystem.update for one particle at dt (the web's rule, as today's DmWfxParticles._update wrote it).
func _euler(rec: Dictionary, dt: float, age: float) -> Dictionary:
	var p: Vector3 = rec["at"]
	var v: Vector3 = rec["v"]
	var life_left: float = rec["life"]
	var t := 0.0
	while t + dt <= age + 1e-9:
		life_left -= dt
		var k := maxf(0.0, 1.0 - float(rec["d"]) * dt)
		v.x *= k
		v.y = v.y * k - float(rec["g"]) * dt
		v.z *= k
		p += v * dt
		t += dt
	var tn := 1.0 - maxf(0.0, life_left) / float(rec["life"])
	var alpha := tn / 0.15 if tn < 0.15 else 1.0 - (tn - 0.15) / 0.85
	var sh: float = rec["shrink"]
	var size: float = float(rec["size"]) * (1.0 - sh * tn * 0.7 if sh >= 0.0 else 1.0 + -sh * tn)
	return {"pos": p, "size": size, "alpha": alpha, "t": t}


func _the_brazier_math() -> void:
	var wisp := {"at": Vector3(1.0, 2.0, 3.0), "v": Vector3(0.05, 1.2, -0.03), "g": -0.8, "d": 1.5, "shrink": 1.0, "life": 0.55, "size": 0.3}
	var ember := {"at": Vector3(-4.0, 1.8, 7.0), "v": Vector3(0.12, 2.1, 0.2), "g": 0.0, "d": 0.3, "shrink": 1.0, "life": 1.3, "size": 0.09}
	var drifter := {"at": Vector3(0.0, 1.0, 0.0), "v": Vector3(0.3, 0.1, 0.0), "g": 0.5, "d": 0.8, "shrink": -0.4, "life": 2.0, "size": 0.2}   # the shrink < 0 branch (it grows)
	for rec: Dictionary in [wisp, ember, drifter]:
		var worst_pos := 0.0
		var worst_size := 0.0
		var worst_alpha := 0.0
		for i in 12:
			var age: float = float(rec["life"]) * (0.05 + 0.08 * float(i))
			var web := _euler(rec, 1.0 / 60.0, age)   # (the web's age is a whole number of frames)
			var mine := DmWfxParticles.pose(rec, float(web["t"]))
			worst_pos = maxf(worst_pos, (web["pos"] as Vector3).distance_to(mine["pos"]))
			worst_size = maxf(worst_size, absf(float(web["size"]) - float(mine["size"])) / float(rec["size"]))
			worst_alpha = maxf(worst_alpha, absf(float(web["alpha"]) - float(mine["alpha"])))
		check(worst_pos < 0.03 and worst_size < 0.02 and worst_alpha < 0.02, "a particle (life %.2f) at any age is where the web's frame-by-frame step puts it: place within %.1f cm, size within %.1f %%, alpha within %.3f" % [
			float(rec["life"]), worst_pos * 100.0, worst_size * 100.0, worst_alpha])
	# the step is the web's at any frame rate too (the closed form is the limit): 20 fps against 60 fps
	var a := _euler(wisp, 1.0 / 60.0, 0.4)
	var b := _euler(wisp, 1.0 / 20.0, 0.4)
	check((a["pos"] as Vector3).distance_to(b["pos"]) < 0.12, "and the web's step at 20 fps ends within 12 cm of its 60 fps one: the closed form is the frame-rate-free answer")


# ---------------------------------------------------------------- the brazier fire's emission
func _the_brazier_emission() -> void:
	var fire := DmWfxBrazierFire.new()
	root.add_child(fire)
	fire.setup(DmData.world())
	fire.rng.seed = 7
	var brazier_props := 0
	for bp in DmData.world()["props"]:
		brazier_props += 1 if bp["prop"] == "brazier" else 0
	check(brazier_props > 0 and fire.braziers.size() == brazier_props, "a fire for each brazier prop of world.json (%d)" % fire.braziers.size())
	var near := Vector3(float(fire.braziers[0].x), 0.0, float(fire.braziers[0].z))   # on the first brazier: it is in range, and whatever else stands near it
	var in_range := 0
	for b: Dictionary in fire.braziers:
		if absf(float(b.x) - near.x) <= DmWfxBrazierFire.RANGE_X and absf(float(b.z) - near.z) <= DmWfxBrazierFire.RANGE_Z:
			in_range += 1
	var ticks := 4000   # 200 s
	for i in ticks:
		fire.tick(near)
		fire.advance(DmWfxBrazierFire.STEP)
	var want := float(in_range * ticks) * (DmWfxBrazierFire.STEP * 10.0 + DmWfxBrazierFire.STEP * 1.5)
	check(in_range >= 1 and absf(float(fire.emitted) - want) < want * 0.05, "%d braziers in range emit the web's rate: %d particles in 200 s against %.0f" % [in_range, fire.emitted, want])
	# out of range: nothing
	var far := Vector3(10000.0, 0.0, 10000.0)
	var before := fire.emitted
	for i in 400:
		fire.tick(far)
	check(fire.emitted == before, "no brazier near the focus emits nothing")
	# an unlit brazier emits nothing
	for b: Dictionary in fire.braziers:
		b["group"] = "out"
	fire.candle_off["out"] = true
	before = fire.emitted
	for i in 400:
		fire.tick(near)
	check(fire.emitted == before, "a brazier whose candle group is out emits nothing")
	fire.queue_free()


func _the_ring() -> void:
	var ring := DmWfxParticles.new()
	root.add_child(ring)
	ring.configure(8, DmFxTex.get_tex("glow"))
	check(not ring.drawing(), "an empty ring draws nothing")
	ring.emit(0.0, 1.0, 0.0, Color.WHITE, 0.1, 0.1, 1.0, 0.5, 0.3)
	check(ring.drawing(), "a particle makes the ring draw")
	for i in 120:
		ring.advance(1.0 / 60.0)
	check(not ring.drawing(), "the ring stops drawing when the last particle has died (2 s on, a life of at most 0.65 s)")
	for i in 20:
		ring.emit(0.0, 1.0, 0.0, Color.WHITE, 0.1, 0.1, 1.0, 0.5, 0.3)
	check(ring.emitted == 21, "a full ring takes the oldest record's place (21 written into 8)")
	ring.queue_free()


# ---------------------------------------------------------------- the mist
func _the_mist() -> void:
	var mist := DmWfxMist.new()
	root.add_child(mist)
	mist.setup(_data.mist)
	var start: PackedVector3Array = mist.pos.duplicate()
	var focus := Vector3(10000.0, 0.0, 10000.0)
	for i in 240:   # four seconds at 60 fps
		mist.tick(1.0 / 60.0, focus)
	var per_4s := int(4.0 / DmWfxMist.STEP_SECONDS)
	check(mist.steps >= per_4s - 1 and mist.steps <= per_4s + 1, "the mist steps every STEP_SECONDS, and once at the start: %d to %d steps in 4 s (%d)" % [per_4s - 1, per_4s + 1, mist.steps])
	var in_box := true
	for p in mist.pos:
		in_box = in_box and absf(p.x - focus.x) <= 45.0 and absf(p.z - focus.z) <= 40.0
	check(in_box, "every puff of the far world is on the box round the focus (the web's wrap: 45 m in x, 40 m in z)")
	# a puff inside the box keeps its place and drifts at its own speed
	var mist2 := DmWfxMist.new()
	root.add_child(mist2)
	mist2.setup(_data.mist)
	var at := start[0]
	mist2.step(1.0, at)   # the focus on puff 0: nothing near it wraps
	check(absf(mist2.pos[0].x - (at.x + mist2.vel[0].x)) < 1e-4 and absf(mist2.pos[0].z - (at.z + mist2.vel[0].y)) < 1e-4, "a puff in the box drifts by its velocity")
	mist.queue_free()
	mist2.queue_free()


# ---------------------------------------------------------------- the presets
func _the_presets() -> void:
	var stage := DmDrawScene.build(root, "graves")
	var dr: DmWorldDressing = stage.world.dressing
	check(dr != null and dr.atmosphere != null and not dr.atmosphere.quality_low, "Ultra: the full weather")
	stage.perf.apply({"graphics": "low"})
	check(dr.atmosphere.quality_low, "Low thins the weather to half")
	stage.perf.apply({"graphics": "medium"})
	check(not dr.atmosphere.quality_low, "Medium has the full weather")
	stage.queue_free()
	await frames(2)


# ---------------------------------------------------------------- the earth beyond the walls
func _the_outside() -> void:
	var w := DmNextWorld.new()
	root.add_child(w)
	w.build(["graves"], true)
	var q := w.builder.get_node_or_null("outside") as MeshInstance3D
	check(q != null and q.mesh is QuadMesh, "one quad is the earth beyond the walls")
	var m := q.material_override as StandardMaterial3D if q != null else null
	var field := (q.mesh as QuadMesh).size if q != null and q.mesh is QuadMesh else Vector2.ZERO
	check(m != null and m.albedo_texture != null and m.albedo_texture.resource_path.ends_with(DmWorldBuilder.OUTSIDE_TEX + ".webp") and m.uv1_scale.x > 1.0, "it is the builder's soil, repeated")
	check(m != null and m.albedo_color.is_equal_approx(DmCompatAlbedo.tint(DmWorldBuilder.OUTSIDE_TEX, Color.html(DmWorldBuilder.OUTSIDE_TINT))) and not m.albedo_color.is_equal_approx(Color.html(DmWorldBuilder.OUTSIDE_TINT)), "in today's albedo: the converter's lift of the tint")
	var lo := Vector2(q.position.x - field.x / 2.0, q.position.z - field.y / 2.0) if q != null else Vector2.ZERO
	var rects_in := q != null
	for id in DmNextWorld.every_area():
		var r: Dictionary = DmContent.area(id)["rect"]
		rects_in = rects_in and float(r["x0"]) >= lo.x and float(r["x1"]) <= lo.x + field.x and float(r["z0"]) >= lo.y and float(r["z1"]) <= lo.y + field.y
	check(rects_in, "and it spans every area of the world")
	check(q != null and q.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and q.position.y < 0.0, "below the floors, casting no shadow")
	w.queue_free()


# ---------------------------------------------------------------- the Binbun scenes' shaders
func _binbun_shaders() -> void:
	var dir := "res://assets/fx/binbun/shaders/"
	var patched := 0
	var kept := 0
	var reads_raw := 0
	var spatial := 0
	var wrong_patch: Array[String] = []   # a shader patched when it does not read COLOR in fragment() (or writes it), or left alone when it does
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".gdshader"):
			continue
		var sh := load(dir + f) as Shader
		var out := DmFxBinbun._srgb_color(sh)
		if not sh.code.contains("shader_type spatial"):
			kept += 1
			continue
		spatial += 1
		if (out != sh) != _reads_color_without_writing(sh.code):
			wrong_patch.append(f)
		if out != sh:
			patched += 1
			var i := out.code.find("void fragment()")
			var body := out.code.substr(i)
			if not body.contains("dm_COLOR = vec4(dm_srgb(COLOR.rgb), COLOR.a)"):
				reads_raw += 1
			var rest := body.replace("dm_COLOR = vec4(dm_srgb(COLOR.rgb), COLOR.a)", "")
			var re := RegEx.new()
			re.compile("\\bCOLOR\\b")
			if re.search(rest.substr(0, rest.find("void light()") if rest.contains("void light()") else rest.length())) != null:
				reads_raw += 1
		else:
			check(DmFxBinbun._srgb_color(sh) == out, "an untouched shader is answered the same again (%s)" % f)
	check(patched > 0 and reads_raw == 0 and wrong_patch.is_empty(), "%d of the %d spatial Binbun shaders read COLOR in fragment() and read it converted from sRGB, none raw (%d); the patched ones are those that read it without writing it (wrong: %s)" % [patched, spatial, reads_raw, str(wrong_patch.slice(0, 3))])
	check(DmFxBinbun._srgb_color(null) == null, "no shader, no copy")


## Whether a spatial shader reads COLOR in fragment() and never writes it (the shaders the sRGB copy is made for), worked out from its source without DmFxBinbun's help.
func _reads_color_without_writing(code: String) -> bool:
	var at := code.find("void fragment()")
	var open := code.find("{", at) if at >= 0 else -1
	if open < 0:
		return false
	var depth := 0
	var close := -1
	for i in range(open, code.length()):
		var ch := code.unicode_at(i)
		if ch == 123:
			depth += 1
		elif ch == 125:
			depth -= 1
			if depth == 0:
				close = i
				break
	if close < 0:
		return false
	var body := code.substr(open + 1, close - open - 1)
	var reads := RegEx.create_from_string("\\bCOLOR\\b")
	var writes := RegEx.create_from_string("\\bCOLOR\\s*(\\.[rgbastpq]+)?\\s*[-+*/]?=[^=]")
	return reads.search(body) != null and writes.search(body) == null
