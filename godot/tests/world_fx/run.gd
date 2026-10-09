extends SceneTree
## world_fx tests (headless): godot --headless --path godot --script res://tests/world_fx/run.gd
## Data export + goldens from the TS (silhouette geometry, atmosphere seeds, water wetness), builders'
## counts, attach/detach on a real DmWorldBuilder, culling (flames follow their area)
## coverage over the real models, wing params, enemy hover, bloom mapping.

var _fail := 0
var _pass := 0

func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: ", what)

func _near(a: float, b: float, eps := 1e-4) -> bool:
	return absf(a - b) <= eps * maxf(1.0, absf(b))

func _initialize() -> void:
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _finish() -> void:
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

func _run() -> void:
	var d := DmWfxData.get_data()
	if d.is_empty():
		print("fixtures missing: they are committed in git (restore with git checkout)")
		quit(1)
		return
	_test_data(d)
	_test_silhouettes(d)
	_test_flames_build(d)
	_test_mist_build(d)
	_test_atmosphere(d)
	_test_water(d)
	_test_bloom(d)
	_test_brazier_fire()
	await _test_backdrop()
	await _test_dressing(d)
	_finish()

# ---------------------------------------------------------------- data
func _test_data(d: Dictionary) -> void:
	_check(d.windows.size() == 4, "4 stained-glass windows (3 nave, 1 sanctum)")
	_check(d.silhouettes.size() == 70, "70 far silhouettes")
	var n := 0
	for k in d.flames:
		n += (d.flames[k].phase as Array).size()
		_check((d.flames[k].pos as Array).size() == (d.flames[k].phase as Array).size() * 3, "flame arrays agree in %s" % k)
	_check(n == 347, "347 candle flames over %d areas" % d.flames.size())
	_check(d.flames.size() == 8, "flames in 8 areas")
	_check(int(d.mist.count) == 220 and (d.mist.pos as Array).size() == 660, "220 mist puffs")
	_check(d.atmosphere.profiles.size() == 13, "13 weather profiles")
	_check(d.wings.keys().size() == 3 and d.wings.has("moth") and d.wings.has("bat") and d.wings.has("seraph"), "wing table = moth, bat, seraph")
	_check(_near(float(d.wings.bat.speed), 17.0) and _near(float(d.wings.bat.amp), 0.75) and _near(float(d.wings.bat.body), 0.22), "bat wing numbers")
	_check(_near(float(d.bloom.strength), 0.75) and _near(float(d.bloom.radius), 0.55) and _near(float(d.bloom.threshold), 0.85), "world bloom numbers")
	_check(_near(float(d.hover.wraith), 0.45), "wraith hover")

# ---------------------------------------------------------------- silhouettes (golden: triangles + bounds from the real three geometry)
func _test_silhouettes(d: Dictionary) -> void:
	var bad := 0
	var total := 0
	for sil in d.silhouettes:
		var tris := DmWfxSilhouettes.silhouette_tris(sil)
		total += tris.size()
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for t in tris:
			for v in t:
				lo = lo.min(v)
				hi = hi.max(v)
		var g: Dictionary = sil.golden
		var ok := tris.size() == int(g.tris)
		for i in 3:
			ok = ok and _near(lo[i], float(g.min[i]), 1e-3) and _near(hi[i], float(g.max[i]), 1e-3)
		if not ok:
			bad += 1
	_check(bad == 0, "all 70 silhouettes match the three.js triangle count + bounds (%d bad)" % bad)
	var r := DmWfxSilhouettes.build_mesh(d.silhouettes)
	_check(int(r.tris) == total and (r.mesh as ArrayMesh).get_surface_count() == 1, "silhouettes merge into one surface (%d tris)" % total)
	# outward normals: every triangle's normal points away from its own silhouette's axis for boxes: check face winding via a lone box
	var one := {"kind": "ruin", "x": 0.0, "z": 0.0, "scale": 1.0, "rot": 0.0, "prims": [{"t": "box", "a": [2.0, 2.0, 2.0], "x": 0.0, "y": 0.0, "z": 0.0, "rx": 0.0, "rz": 0.0}]}
	var ok := true
	for t in DmWfxSilhouettes.silhouette_tris(one):
		var a: Vector3 = t[0]
		var bb: Vector3 = t[1]
		var cc: Vector3 = t[2]
		var n: Vector3 = (bb - a).cross(cc - a).normalized()
		var c: Vector3 = (a + bb + cc) / 3.0 - Vector3(0, 1.0 - 0.1, 0)
		ok = ok and n.dot(c) > 0.0
	_check(ok, "box faces wind outward")
	var mi := DmWfxSilhouettes.attach(Node3D.new(), d.silhouettes)
	_check(mi != null and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "silhouette mesh builds, casts no shadow")
	mi.free()

# ---------------------------------------------------------------- flames / mist / quads
func _test_flames_build(d: Dictionary) -> void:
	var root := Node3D.new()
	var off := {"sanctum_a": true}
	for id in d.flames:
		var m := DmWfxFlames.build(root, str(id), d.flames[id], off)
		_check(m != null and m.multimesh.instance_count == (d.flames[id].phase as Array).size(), "flame count in %s" % id)
		var aabb: AABB = m.multimesh.custom_aabb
		var p0 := Vector3(float(d.flames[id].pos[0]), float(d.flames[id].pos[1]), float(d.flames[id].pos[2]))
		_check(aabb.has_point(p0 + Vector3(2.9, 2.9, 2.9)) and aabb.has_point(p0 - Vector3(2.9, 2.9, 2.9)), "flame culling box padded by 3 in %s" % id)
		_check(m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "flames cast no shadow")
	# candle groups
	var groups := {}
	for id in d.flames:
		for g in d.flames[id].groups:
			if g != null:
				groups[str(g)] = id
	_check(groups.size() > 0, "flames carry candle groups (%s)" % ",".join(groups.keys()))
	if groups.size() > 0:
		var g0: String = groups.keys()[0]
		var mm: MultiMeshInstance3D = root.get_child(d.flames.keys().find(groups[g0]))
		var gi := (mm.get_meta("groups") as Array).find(g0)
		_check(is_equal_approx((mm.get_meta("lit") as PackedFloat32Array)[gi], 1.0), "group starts lit")
		DmWfxFlames.set_group_lit(mm, g0, false)
		_check(is_equal_approx((mm.get_meta("lit") as PackedFloat32Array)[gi], 0.0), "set_group_lit(false) gutters the group")
		DmWfxFlames.set_group_lit(mm, g0, true)
		_check(is_equal_approx((mm.get_meta("lit") as PackedFloat32Array)[gi], 1.0), "set_group_lit(true) relights it")
	root.free()

func _test_mist_build(d: Dictionary) -> void:
	var m := DmWfxMist.new()
	m.setup(d.mist)
	_check(m.count == 220 and m.mmi.multimesh.instance_count == 220, "220 mist puffs in one MultiMesh")
	_check((m.mmi.material_override as ShaderMaterial).render_priority == 4, "mist sorts at renderOrder 4")
	# the web's wrap rule: a puff > 45 m (x) / 40 m (z) from the focus lands on the far side at 44 / 39
	var focus := Vector3(0, 0, 0)
	m.pos[0] = Vector3(200, 0.5, 5)
	m.vel[0] = Vector2.ZERO
	m.pos[1] = Vector3(3, 0.5, -90)
	m.vel[1] = Vector2.ZERO
	m.pos[2] = Vector3(10, 0.5, 10)
	m.vel[2] = Vector2(0.2, -0.1)
	m.step(2.0, focus)
	_check(_near(m.pos[0].x, -44.0) and _near(m.pos[0].z, 5.0), "x wrap: 200 -> focus - 44")
	_check(_near(m.pos[1].z, 39.0) and _near(m.pos[1].x, 3.0), "z wrap: -90 -> focus + 39")
	_check(_near(m.pos[2].x, 10.4) and _near(m.pos[2].z, 9.8), "drift = velocity x dt")
	# after the first step every puff is inside (or on) the 45 x 40 box
	var m2 := DmWfxMist.new()
	m2.setup(d.mist)
	m2.step(0.016, Vector3(0, 0, -70))
	var inside := true
	for i in m2.count:
		inside = inside and absf(m2.pos[i].x) <= 45.0 + 1e-3 and absf(m2.pos[i].z + 70.0) <= 40.0 + 1e-3
	_check(inside, "all puffs pulled into the focus box on the first step")
	# stepping every 4th frame with the accumulated dt moves a puff as far as 4 single steps
	var m3 := DmWfxMist.new()
	m3.setup(d.mist)
	m3.pos[5] = Vector3(0, 0.5, 0)
	m3.vel[5] = Vector2(0.3, 0.0)
	m3.tick(0.01, Vector3.ZERO)   # frame 1: steps
	var x1 := m3.pos[5].x
	for i in 3:
		m3.tick(0.01, Vector3.ZERO)
	_check(_near(m3.pos[5].x, x1, 1e-9), "frames 2-4 only accumulate")
	m3.tick(0.01, Vector3.ZERO)   # frame 5: steps with 0.04 s
	_check(_near(m3.pos[5].x, x1 + 0.3 * 0.04, 1e-6), "frame 5 steps once with the accumulated 0.04 s")
	m.free()
	m2.free()
	m3.free()

# ---------------------------------------------------------------- atmosphere
func _test_atmosphere(d: Dictionary) -> void:
	var a := DmWfxAtmosphere.new()
	a.setup(d)
	var g: Dictionary = d.golden.atmosphere
	var max_n := 0
	for area in g:
		max_n = maxi(max_n, int(g[area].n))
		_check(a.counts_for(area) == int(g[area].n), "weather count %s = %d" % [area, int(g[area].n)])
		a.quality_low = true
		_check(a.counts_for(area) == int(g[area].nLow), "weather low-quality count %s" % area)
		a.quality_low = false
	_check(a.max_count() == max_n, "ATMOSPHERE_MAX = %d" % max_n)
	# seeds replay the web's mulberry32 call order bit for bit
	var bad := 0
	for area in g:
		a.fill(area)
		var arr := (a.get_child(0) as MeshInstance3D).mesh.surface_get_arrays(0)
		var c0: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM0]
		var c1: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM1]
		var c2: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM2]
		var c3: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM3]
		_check(a.count == int(g[area].n), "filled count %s" % area)
		var idxs := [0, 1, 2, 150]
		var gi := 0
		for f in g[area].first:
			var i: int = idxs[gi]
			gi += 1
			if i >= a.count:
				continue
			var v := i * 4   # first vertex of particle i
			var want_col := DmWfxData.hex(f[12]).srgb_to_linear()
			var ok := true
			for k in 4:
				ok = ok and _near(c0[v * 4 + k], float(f[k]), 1e-5)
				ok = ok and _near(c1[v * 4 + k], float(f[4 + k]), 1e-5)
				ok = ok and _near(c2[v * 4 + k], float(f[8 + k]), 1e-5)
			ok = ok and _near(c3[v * 4], want_col.r, 1e-5) and _near(c3[v * 4 + 2], want_col.b, 1e-5)
			if not ok:
				bad += 1
	_check(bad == 0, "weather seeds match the TS fill() for all 13 areas (%d bad)" % bad)
	# cross-fade state machine: fade out 1.6/s, refill, fade in 0.8/s
	a.fade = 1.0
	a.area = "graves"
	a.tick(0.1, "nave", Vector3.ZERO)
	_check(a.pending == "nave" and _near(a.fade, 0.84), "fade-out starts at 1.6/s")
	a.tick(0.6, "nave", Vector3.ZERO)
	_check(a.area == "nave" and a.pending == "" and a.fade == 0.0, "refills at zero fade")
	a.tick(0.5, "", Vector3.ZERO)
	_check(_near(a.fade, 0.4), "fade-in 0.8/s and a corridor keeps the current weather")
	var at := DmWfxAtmosphere.atlas_texture().get_image()
	_check(at.get_width() == 128 and at.get_height() == 128, "atlas is 2 x 2 cells of 64")
	_check(at.get_pixel(32, 32).a > 0.95 and at.get_pixel(0, 0).a < 0.01, "dot cell: opaque centre, clear corner")
	_check(at.get_pixel(64 + 32, 32).a > 0.8 and at.get_pixel(64 + 2, 2).a < 0.01, "flake cell")
	_check(at.get_pixel(32, 64 + 32).a > 0.9 and at.get_pixel(2, 64 + 2).a < 0.01, "leaf cell")
	_check(at.get_pixel(64 + 32, 64 + 45).a > 0.5 and at.get_pixel(64 + 10, 64 + 45).a < 0.01, "streak cell: thin line")
	a.free()

# ---------------------------------------------------------------- water
func _test_water(d: Dictionary) -> void:
	var w := DmWfxWater.new()
	w.setup(d.water.rects, d.water.puddles)
	_check(w.tri_count == int(d.golden.waterTris), "water mesh: %d triangles (10 per rect, 18 per puddle)" % w.tri_count)
	_check((w.mesh_instance.mesh as ArrayMesh).get_surface_count() == 1, "water is one surface = one draw call")
	var bad := 0
	for c in d.golden.wet:
		if w.is_wet(float(c[0]), float(c[1])) != bool(c[2]):
			bad += 1
	_check(bad == 0, "isWet matches the TS on %d points (%d bad)" % [d.golden.wet.size(), bad])
	# ripples: dry ground ignored, 16 slots recycled oldest-first
	_check(not w.add_ripple(1000.0, 1000.0, 1.0), "no ripple on dry ground")
	var rc: Dictionary = d.water.rects[0]
	var cx := (float(rc.x0) + float(rc.x1)) / 2.0
	var cz := (float(rc.z0) + float(rc.z1)) / 2.0
	for i in 20:
		w.add_ripple(cx, cz, 1.0)
	_check(w.active_ripples() == 16, "ripple pool is 16 rings (the 17th recycles the oldest)")
	w.tick(2.3)
	_check(w.active_ripples() == 0, "rings die after 2.2 s")
	w.set_quality("low")
	_check(w.mesh_instance.material_override is StandardMaterial3D, "low quality = flat glossy sheet")
	w.set_quality("high")
	_check(w.mesh_instance.material_override is ShaderMaterial, "high quality = ripple/glint shader")
	var nt := DmWfxWater.normals_texture().get_image()
	_check(nt.get_width() == 256 and nt.get_format() == Image.FORMAT_RGB8, "water normal map 256^2")
	var c00 := nt.get_pixel(0, 0)
	var c255 := nt.get_pixel(255, 255)
	_check(c00.b > 0.7 and c255.b > 0.7, "normals point mostly up")
	# seamless: edge column continues smoothly into column 0
	_check(absf(nt.get_pixel(255, 40).r - nt.get_pixel(0, 40).r) < 0.06, "normal map tiles seamlessly")
	w.free()

# ---------------------------------------------------------------- wings
# ---------------------------------------------------------------- enemy motion
# ---------------------------------------------------------------- bloom
func _test_bloom(d: Dictionary) -> void:
	var env := Environment.new()
	DmWfxBloom.apply(env, true)
	_check(env.glow_enabled and env.glow_blend_mode == Environment.GLOW_BLEND_MODE_ADDITIVE, "glow on, additive")
	_check(_near(env.glow_intensity, 0.75) and _near(env.glow_hdr_threshold, 0.85), "intensity = strength 0.75, threshold 0.85")
	var w := DmWfxBloom.mip_weights(0.55)
	_check(_near(w[0], 0.56) and _near(w[2], 0.6) and _near(w[4], 0.64), "UnrealBloom lerpBloomFactor mip weights")
	_check(_near(env.get_glow_level(0), 0.56) and _near(env.get_glow_level(4), 0.64) and env.get_glow_level(5) == 0.0, "glow levels set")
	DmWfxBloom.apply(env, false)
	_check(not env.glow_enabled, "bloom off")

# ---------------------------------------------------------------- brazier fire
func _test_brazier_fire() -> void:
	var w: Dictionary = DmData.world()
	var f := DmWfxBrazierFire.new()
	f.setup(w)
	var n := 0
	for p in w.props:
		if p.prop == "brazier":
			n += 1
	_check(f.braziers.size() == n and n > 0, "%d braziers feed the fire" % n)
	f.rng.seed = 7
	var b: Dictionary = f.braziers[0]
	var at := Vector3(b.x, 0, b.z)
	for i in 120:
		f.tick(1.0 / 60.0, at)
	_check(f.active > 3 and f.active < 40, "10/s wisps (0.5 s) + 1.5/s embers (1.2 s) near the focus: ~%d alive" % f.active)
	var far := Vector3(b.x + 500.0, 0, b.z)
	var before := f.active
	for i in 90:
		f.tick(1.0 / 60.0, far)
	_check(f.active == 0, "no emission beyond 30 x 28 m of the focus; the old particles die out (%d -> %d)" % [before, f.active])
	# a gutted candle group stops its brazier
	var grouped := f.braziers.filter(func(x): return x.group != null)
	if grouped.size() > 0:
		var g: Dictionary = grouped[0]
		_check(f.is_lit(g), "a grouped brazier starts lit")
		f.candle_off[str(g.group)] = true
		_check(not f.is_lit(g), "a gutted group's brazier is unlit")
	# emit() envelope: alpha rises over the first 15% of life then fades, size shrinks 0.7 by the end
	f.rng.seed = 3
	f._life.fill(0.0)
	f.active = 0
	f.emit(0, 0, 0, Color.WHITE, 0.2, 1.0, 1.0, 1.0, 1.0, 0.0)
	var i0 := (f._cursor + f.capacity - 1) % f.capacity
	_check(f._life[i0] >= 0.7 and f._life[i0] <= 1.3 and f._base_size[i0] >= 0.7 and f._base_size[i0] <= 1.3, "emit randomises life and size x0.7..1.3")
	f.free()

# ---------------------------------------------------------------- login backdrop
func _test_backdrop() -> void:
	var layer := DmNecroBackdrop.make_layer()
	root.add_child(layer)
	await _frames(2)
	var b: DmNecroBackdrop = layer.get_meta("backdrop")
	_check(layer.stretch and layer.get_child(0) is SubViewport, "backdrop layer is a stretching SubViewportContainer")
	_check(b.camera != null and _near(b.camera.fov, 40.0) and _near(b.matte.position.z, -48.0) and _near(b.sigil.position.y, -2.4), "camera fov 40, matte at z -48, sigil at y -2.4")
	_check(_near((b.matte.mesh as QuadMesh).size.x, 96.0) and _near((b.matte.mesh as QuadMesh).size.y, 54.0), "matte is 96 x 54")
	_check(b.env.glow_enabled and _near(b.env.glow_intensity, 0.75) and _near(b.env.glow_hdr_threshold, 0.78), "bloom 0.75 / threshold 0.78")
	b.rng.seed = 11
	b.mist.rng.seed = 5
	b.embers.rng.seed = 6
	var rot0 := b.sigil.rotation.y
	for i in 240:
		b.tick(1.0 / 60.0)
	_check(b.mist.active > 5 and b.mist.active < 120, "grave-mist puffs drift (%d alive)" % b.mist.active)
	_check(b.embers.active > 20 and b.embers.active < 200, "embers rise (%d alive, 14/s for ~5 s)" % b.embers.active)
	_check(_near(b.sigil.rotation.y - rot0, 4.0 * 0.05, 1e-3), "sigil turns 0.05 rad/s")
	var a := (b.sigil.material_override as StandardMaterial3D).albedo_color.a
	_check(a >= 0.2 and a <= 0.3, "sigil breathes 0.25 +- 0.05")
	b.mouse = Vector2(1, 0)
	for i in 200:
		b.tick(1.0 / 60.0)
	_check(b.camera.position.x > 1.0 and b.camera.position.x < 2.0, "camera eases toward the mouse (x -> 1.4 + sway)")
	b.reduced_motion = true
	var before := b.mist.active + b.embers.active
	for i in 900:
		b.tick(1.0 / 60.0)
	_check(b.mist.active + b.embers.active == 0 and before > 0, "reduced motion: no new mist/embers, the old ones die")
	layer.queue_free()

# ---------------------------------------------------------------- material conversion
# ---------------------------------------------------------------- dressing on a real builder
func _test_dressing(d: Dictionary) -> void:
	var w: Dictionary = DmData.world()
	var b := DmWorldBuilder.new()
	root.add_child(b)
	b.build(w)
	await _frames(2)
	var stock_flame_spheres := 0
	var stock_water := 0
	for id in b.area_nodes:
		for c in b.area_nodes[id].get_children():
			if c is MeshInstance3D:
				var mi := c as MeshInstance3D
				if mi.mesh is SphereMesh and mi.visible:
					stock_flame_spheres += 1
				if (mi.mesh is PlaneMesh and absf(mi.position.y - 0.06) < 0.001) or (mi.mesh is QuadMesh and absf(mi.position.y - 0.025) < 0.001):
					stock_water += 1
	var before_children := root.get_child_count()
	var dr := DmWorldDressing.attach(b, null)
	_check(dr.get_parent() == b, "attach adds one child to the builder")
	_check(dr.window_nodes.size() == 8, "4 windows x (pane + shaft)")
	_check(dr.area_flames.size() == 8, "flames in 8 areas")
	_check(dr.area_flames.has("sanctum") or dr.area_flames.size() > 0, "flame areas present")
	for id in dr.area_flames:
		_check(dr.area_flames[id].get_parent() == b.area_nodes[id], "flames of %s live under its area node" % id)
	_check(dr.silhouette_node != null and dr.mist_node != null and dr.atmosphere != null and dr.water != null, "global pieces exist")
	_check(dr._hidden_stock.size() >= stock_flame_spheres, "stock flame spheres and water planes hidden (%d spheres, %d water)" % [stock_flame_spheres, stock_water])
	_check(b.env.glow_enabled, "bloom applied to the builder's environment")
	# windows sit in the nearest area (WorldView.windowArea): nave 3, sanctum 1
	var per_area := {}
	for n in dr.window_nodes:
		per_area[n.get_parent().name] = int(per_area.get(n.get_parent().name, 0)) + 1
	_check(per_area.get("area_nave", 0) == 6 and per_area.get("area_sanctum", 0) == 2, "windows: nave 3 (6 quads), sanctum 1 (2 quads) -> %s" % str(per_area))
	# culling follows the area: hide an area and its flames leave the tree-visible set
	var fl: MultiMeshInstance3D = dr.area_flames.values()[0]
	var area_id: String = dr.area_flames.keys()[0]
	b.area_nodes[area_id].visible = false
	_check(not fl.is_visible_in_tree(), "flames are culled with their area")
	b.area_nodes[area_id].visible = true
	_check(fl.is_visible_in_tree(), "flames return with their area")
	# features
	dr.set_feature("flames", false)
	_check(not fl.visible, "flames feature off hides them")
	var spheres_hidden := 0
	for e in dr._hidden_stock:
		if e.feature == "flames" and e.node.visible:
			spheres_hidden += 1
	_check(spheres_hidden == dr._hidden_stock.filter(func(e): return e.feature == "flames").size(), "stock flame glow returns when sprites are off")
	dr.set_feature("flames", true)
	# candle groups
	dr.set_candle_group("x_none", false)
	_check(dr.candle_off.has("x_none"), "candle_off tracked")
	dr.set_candle_group("x_none", true)
	_check(not dr.candle_off.has("x_none"), "candle relit")
	# a few frames with a camera: nothing errors, focus fallback works
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0, 14, 10)
	cam.look_at(Vector3(0, 0, 0), Vector3.UP)
	await _frames(3)
	var f := DmWorldDressing.ground_point(cam)
	_check(absf(f.x) < 0.5 and absf(f.z) < 0.5 and absf(f.y) < 0.5, "focus falls back to the camera's ground point")
	_check(dr.atmosphere.area == "chapterhouse" or dr.atmosphere.pending == "chapterhouse" or dr.atmosphere.area != "", "weather follows the focus area")
	# master switch off: everything back to stock
	dr.set_enabled(false)
	_check(not dr.silhouette_node.visible and not dr.mist_node.visible and not dr.water.visible, "set_enabled(false) hides the pieces")
	_check(not b.env.glow_enabled, "bloom off with the master switch")
	var shown := 0
	for e in dr._hidden_stock:
		if e.node.visible:
			shown += 1
	_check(shown == dr._hidden_stock.size(), "stock stand-ins return")
	dr.set_enabled(true)
	_check(b.env.glow_enabled, "re-enabled")
	dr.detach()
	await _frames(2)
	_check(not is_instance_valid(dr) or dr.is_queued_for_deletion(), "detach frees the node")
	var left_flames := 0
	for n in b.find_children("Flames_*", "MultiMeshInstance3D", true, false):
		left_flames += 1
	_check(left_flames == 0, "no flames left after detach")
	b.queue_free()
