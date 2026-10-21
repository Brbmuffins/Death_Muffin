extends SceneTree
## world_fx tests (headless): godot --headless --path client --script res://tests/world_fx/run.gd
## Data export + goldens from the TS (silhouette geometry, atmosphere seeds, water wetness), builders'
## counts, attach/detach on a real DmWorldBuilder, culling (flames follow their area)
## coverage over the real models, wing params, enemy hover, bloom mapping.
## Not here: the old game's brazier fire step (`tick(dt, focus)`) and its dressing attached to a runtime DmWorldBuilder with stock stand-ins to hide; the client's dressing sits on
## the area scenes and is held by tests/dressing.gd (client/world_fx/README.md "World dressing").

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
	print("%s world_fx %d checks%s" % ["PASS" if _fail == 0 else "FAIL", _pass + _fail, "" if _fail == 0 else " (%d failed)" % _fail])
	quit(1 if _fail > 0 else 0)

func _run() -> void:
	var d := DmWfxData.get_data()
	if d.is_empty():
		print("FAIL world_fx: fixtures missing: they are committed in git (restore with git checkout)")
		quit(1)
		return
	_test_data(d)
	_test_silhouettes(d)
	_test_flames_build(d)
	_test_mist_build(d)
	_test_atmosphere(d)
	_test_water(d)
	_test_bloom(d)
	_finish()

# ---------------------------------------------------------------- data
func _test_data(d: Dictionary) -> void:
	_check(not d.windows.is_empty(), "stained-glass windows (%d)" % d.windows.size())
	_check(not d.silhouettes.is_empty(), "far silhouettes (%d)" % d.silhouettes.size())
	var n := 0
	for k in d.flames:
		n += (d.flames[k].phase as Array).size()
		_check((d.flames[k].pos as Array).size() == (d.flames[k].phase as Array).size() * 3, "flame arrays agree in %s" % k)
	var world: Dictionary = DmData.world()
	var want_flames := 0
	var want_areas := {}
	for p in world.props:
		var fl := int(((world.propSpecs as Dictionary).get(String(p.prop), {}) as Dictionary).get("light", {}).get("flames", 0))
		if fl > 0:
			want_flames += fl
			want_areas[String(p.area)] = true
	_check(n > 0 and n == want_flames and d.flames.size() == want_areas.size(), "the candle flames are the candle props' flames in world.json (%d over %d areas)" % [n, d.flames.size()])
	_check(int(d.mist.count) > 0 and (d.mist.pos as Array).size() == int(d.mist.count) * 3, "mist puffs: three numbers each (%d)" % int(d.mist.count))
	_check(not d.atmosphere.profiles.is_empty(), "weather profiles (%d)" % d.atmosphere.profiles.size())
	var wings_ok: bool = not d.wings.is_empty()
	for kind in d.wings:
		var w: Dictionary = d.wings[kind]
		wings_ok = wings_ok and float(w.speed) > 0.0 and float(w.amp) > 0.0 and float(w.body) > 0.0
	_check(wings_ok, "wing table: every kind has a positive speed, amplitude and body (%s)" % ", ".join(d.wings.keys()))
	_check(float(d.bloom.strength) > 0.0 and float(d.bloom.radius) >= 0.0 and float(d.bloom.threshold) > 0.0, "world bloom numbers are there")
	var hover_ok: bool = not d.hover.is_empty()
	for kind in d.hover:
		hover_ok = hover_ok and float(d.hover[kind]) >= 0.0
	_check(hover_ok, "enemy hover heights (%s)" % ", ".join(d.hover.keys()))

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
	_check(bad == 0, "all %d silhouettes match the three.js triangle count + bounds (%d bad)" % [d.silhouettes.size(), bad])
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
	_check(m.count == int(d.mist.count) and m.mmi.multimesh.instance_count == m.count, "the data's %d mist puffs in one MultiMesh" % m.count)
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
	# the client's mist steps every STEP_SECONDS with the dt accumulated since the last step, and its first tick at once (today's stepped every 4th frame; client/code.list "Ported")
	var m3 := DmWfxMist.new()
	m3.setup(d.mist)
	m3.pos[5] = Vector3(0, 0.5, 0)
	m3.vel[5] = Vector2(0.3, 0.0)
	var dt := DmWfxMist.STEP_SECONDS / 16.0   # sixteen of them are one step's time, exact in binary
	m3.tick(dt, Vector3.ZERO)   # the first tick steps at once
	_check(m3.steps == 1, "the first tick steps at once")
	var x1 := m3.pos[5].x
	for i in 15:
		m3.tick(dt, Vector3.ZERO)
	_check(m3.steps == 1 and _near(m3.pos[5].x, x1, 1e-9), "the next 15 ticks (a step's time less one tick) only accumulate")
	m3.tick(dt, Vector3.ZERO)   # the 16th: one step's time
	_check(m3.steps == 2 and _near(m3.pos[5].x, x1 + 0.3 * DmWfxMist.STEP_SECONDS, 1e-6), "a step comes after STEP_SECONDS, with the accumulated time")
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
	_check(bad == 0, "weather seeds match the TS fill() for all %d areas (%d bad)" % [g.size(), bad])
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
	_check(w.tri_count == int(d.golden.waterTris), "water mesh: %d triangles, as the TS builds them" % w.tri_count)
	_check((w.mesh_instance.mesh as ArrayMesh).get_surface_count() == 1, "water is one surface = one draw call")
	var bad := 0
	for c in d.golden.wet:
		if w.is_wet(float(c[0]), float(c[1])) != bool(c[2]):
			bad += 1
	_check(bad == 0, "isWet matches the TS on %d points (%d bad)" % [d.golden.wet.size(), bad])
	# ripples: dry ground ignored, RIPPLES slots recycled oldest-first
	_check(not w.add_ripple(1000.0, 1000.0, 1.0), "no ripple on dry ground")
	var rc: Dictionary = d.water.rects[0]
	var cx := (float(rc.x0) + float(rc.x1)) / 2.0
	var cz := (float(rc.z0) + float(rc.z1)) / 2.0
	for i in DmWfxWater.RIPPLES + 4:
		w.add_ripple(cx, cz, 1.0)
	_check(w.active_ripples() == DmWfxWater.RIPPLES, "ripple pool is %d rings (the next one recycles the oldest)" % DmWfxWater.RIPPLES)
	w.tick(DmWfxWater.RIPPLE_LIFE + 0.1)
	_check(w.active_ripples() == 0, "rings die after RIPPLE_LIFE (%.1f s)" % DmWfxWater.RIPPLE_LIFE)
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
	# the client's glow is the data's strength at DmWfxBloom.GAIN on its finest mips (LEVELS) only: on Forward+ the full mapping glows far wider than today's Compatibility did (dm_wfx_bloom.gd)
	_check(_near(env.glow_intensity, float(d.bloom.strength) * DmWfxBloom.GAIN) and _near(env.glow_hdr_threshold, float(d.bloom.threshold)), "intensity = the data's strength x gain, threshold = the data's")
	# UnrealBloom's lerpBloomFactor mix(f, 1.2 - f, radius) for a radius of the test's own, 0.25: the factors 1.0, 0.8, 0.6, 0.4, 0.2 give 0.8, 0.7, 0.6, 0.5, 0.4
	var w := DmWfxBloom.mip_weights(0.25)
	var want_w := [0.8, 0.7, 0.6, 0.5, 0.4]
	var w_ok := w.size() == want_w.size()
	for i in mini(w.size(), want_w.size()):
		w_ok = w_ok and _near(float(w[i]), float(want_w[i]))
	_check(w_ok, "UnrealBloom lerpBloomFactor mip weights")
	var w2 := DmWfxBloom.mip_weights(float(d.bloom.radius))
	var levels_ok := true
	for i in 7:
		levels_ok = levels_ok and _near(env.get_glow_level(i), float(w2[i]) if i < DmWfxBloom.LEVELS else 0.0)
	_check(levels_ok, "glow levels: the finest mips at the data radius's weights, the rest 0")
	DmWfxBloom.apply(env, false)
	_check(not env.glow_enabled, "bloom off")

