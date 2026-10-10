extends SceneTree
## Creature material sharing. godot --headless --path godot --script res://tests/creature_mat/run.gd
## Every body of one model + render variant shares ONE ShaderMaterial; what differs per body (tint, emissive/hit flash, opacity, rim, gear tint,
## wing phase) lives in instance uniforms and never leaks to another body. Variants that need another render state stay separate shared materials.

var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)

func _mat(c: DmCreature) -> Array:
	var out: Array = []
	for mi in c.root.find_children("*", "MeshInstance3D", true, false):
		for s in (mi as MeshInstance3D).mesh.get_surface_count():
			out.append((mi as MeshInstance3D).get_active_material(s))
	return out

func _mi(c: DmCreature) -> MeshInstance3D:
	return c.root.find_children("*", "MeshInstance3D", true, false)[0]

func _unique(cs: Array) -> int:
	var ids := {}
	for c in cs:
		for m in _mat(c):
			ids[(m as Material).get_instance_id()] = true
	return ids.size()

func _run() -> void:
	var K := 12
	# K bodies of the same model, each with its own look (tint / elite emissive / risen), flash and fade states
	var plain: Array = []
	for i in K:
		var o := {"hitstop": true}
		if i % 3 == 1:
			o = {"hitstop": true, "emissive": 0x4a1f8a, "emissive_intensity": 0.14}
		elif i % 3 == 2:
			o = {"hitstop": true, "tint": 0x8a8078, "emissive": 0x2a3a18, "emissive_intensity": 0.3}
		var c := DmCreature.new("grave_robber", o)
		root.add_child(c.root)
		plain.append(c)
	check(plain.all(func(c): return c.loaded), "bodies built")
	check(_unique(plain) == 1, "%d bodies of one model (3 different looks) share one material (%d)" % [K, _unique(plain)])
	# flash one body: its instance values change, nobody else's
	var other_before: Vector4 = _mi(plain[1]).get_instance_shader_parameter("emis4")
	var own_before: Vector4 = _mi(plain[0]).get_instance_shader_parameter("emis4")
	plain[0].set_flash(1.0)
	var own_after: Vector4 = _mi(plain[0]).get_instance_shader_parameter("emis4")
	check(own_after != own_before and own_after.w > own_before.w, "hit flash raises this body's emissive instance uniform")
	check(_mi(plain[1]).get_instance_shader_parameter("emis4") == other_before, "hit flash does not touch another body")
	plain[0].set_flash(0.0)
	check(_mi(plain[0]).get_instance_shader_parameter("emis4").is_equal_approx(own_before), "flash ends back at the base emissive")
	# the looks differ per body
	var t0: Vector4 = _mi(plain[0]).get_instance_shader_parameter("tint_op")
	var t2: Vector4 = _mi(plain[2]).get_instance_shader_parameter("tint_op")
	check(t0.x == 1.0 and t2.x < 0.9, "tint is per body (plain %.2f, risen %.2f)" % [t0.x, t2.x])
	# fade: a faded body swaps to the shared fade material; two faded bodies share it; opacity is per body
	plain[0].set_opacity(0.4)
	plain[3].set_opacity(0.7)
	var m0: Material = _mat(plain[0])[0]
	check(m0 == _mat(plain[3])[0] and m0 != _mat(plain[1])[0], "faded bodies share one fade material, apart from the opaque one")
	check(absf(_mi(plain[0]).get_instance_shader_parameter("tint_op").w - 0.4) < 1e-4 and absf(_mi(plain[3]).get_instance_shader_parameter("tint_op").w - 0.7) < 1e-4, "opacity is per body")
	check(_unique(plain) == 2, "opaque + fade = 2 materials for %d bodies (%d)" % [K, _unique(plain)])
	plain[0].set_opacity(1.0)
	check(_mat(plain[0])[0] == _mat(plain[1])[0], "opacity back to 1 returns to the opaque material")
	# spectral / winged / gear variants are their own shared materials
	var sp: Array = []
	for i in 4:
		var c := DmCreature.new("skeleton_thrall", {"tint": 0xb9c4ff, "emissive": 0x8f9ed1, "emissive_intensity": 1.1, "spectral": true, "rim": {"color": 0x6fe0b0, "strength": 1.0}})
		root.add_child(c.root)
		sp.append(c)
	check(_unique(sp) == 1, "4 spectral thralls share one material")
	var rim: Vector4 = _mi(sp[0]).get_instance_shader_parameter("rim")
	check(rim.w == 1.0 and rim.y > 0.0, "rim strength/colour sit in the instance uniform")
	var gear: Array = []
	for i in 4:
		var c := DmCreature.new("skeleton_thrall", {"gear_tint": true, "tint": 0xf4ecff})
		root.add_child(c.root)
		gear.append(c)
	check(_unique(gear) == 1, "4 gear-tint thralls share one material")
	gear[0].set_region_tint("chest", {"color": 0xd9a441, "strength": 0.7})
	check(_mi(gear[0]).get_instance_shader_parameter("gt0").w > 0.5 and _mi(gear[1]).get_instance_shader_parameter("gt0").w == 0.0, "gear tint is per body")
	check(_unique(gear + sp + plain) == 4, "opaque + fade + spectral + gear: 4 materials for %d bodies (%d)" % [K + 8, _unique(gear + sp + plain)])
	var wings: Array = []
	for i in 5:
		var c := DmCreature.new("shroud_moth", {"fallback": "choir_wraith", "wings": {"speed": 14.0, "amp": 0.6, "body": 0.3}})
		root.add_child(c.root)
		wings.append(c)
	check(_unique(wings) == 1, "5 moths share one material")
	check(_mi(wings[0]).get_instance_shader_parameter("wing_root").y != _mi(wings[1]).get_instance_shader_parameter("wing_root").y, "wing phase is per body")
	# a recycled body gets its base look back
	plain[2].set_flash(1.0)
	plain[2].set_opacity(0.3)
	plain[2].recycle_reset()
	check(_mat(plain[2])[0] == _mat(plain[1])[0] and _mi(plain[2]).get_instance_shader_parameter("tint_op").w == 1.0, "recycle_reset restores opacity and material")
	print("INFO materials: %d bodies, %d shared creature materials built" % [K + 8 + 5, DmCreatureMat.shared_count()])
	print("creature_mat: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
