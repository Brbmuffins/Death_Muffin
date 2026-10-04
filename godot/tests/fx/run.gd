extends SceneTree
## DmFx tests: godot --headless --path godot --script res://tests/fx/run.gd
## Every effect id instantiates; SPELL_FX colours match the web source; animation lengths / particle lifetimes match the converted
## JSON; the caps (24 one-shots, 32 loopers, 160 combat transients) hold; the particle rings, roles and motif budget behave.

var passed := 0
var failed := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var data := DmFxData.data()
	check(not data.is_empty(), "fx_data.json loads")
	_test_scenes()
	_test_spell_colors()
	_test_json_match()
	await _test_caps()
	await _test_prims()
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _test_scenes() -> void:
	var ids: Array = DmFxData.catalog("effects")
	check(ids.size() >= 64, "catalog has %d spawnable effects" % ids.size())
	var man: Dictionary = JSON.parse_string(_read("res://assets/fx/binbun/manifest.json"))
	var in_man := {}
	for e in man["effects"]:
		in_man[e["id"]] = e
	for id in ids:
		check(in_man.has(id), "%s in manifest" % id)
		var s := load("res://assets/fx/binbun/%s.tscn" % id) as PackedScene
		check(s != null, "%s loads" % id)
		if s == null:
			continue
		var n := s.instantiate()
		check(n is Node3D, "%s instantiates as Node3D" % id)
		var has_visual := false
		var stack: Array = [n]
		while not stack.is_empty():
			var c: Node = stack.pop_back()
			if c is GPUParticles3D or c is MeshInstance3D or c is Decal:
				has_visual = true
			stack.append_array(c.get_children())
		check(has_visual, "%s has particles or meshes" % id)
		n.free()
	for k in DmFxData.catalog("world_kits"):
		check(in_man.has(k), "world kit %s converted" % k)
		check(load(in_man[k]["scene"]) != null, "world kit %s loads" % k)


func _test_spell_colors() -> void:
	var src := _read("res://../src/content/abilities.ts")
	var start := src.find("export const SPELL_FX = {")
	check(start >= 0, "SPELL_FX found in abilities.ts")
	var block := src.substr(start)
	block = block.substr(0, block.find("} as const;"))
	var re := RegEx.new()
	re.compile("(?m)^\\s*(\\w+): \\{([^}]*)\\}")
	var pair := RegEx.new()
	pair.compile("(\\w+): 0x([0-9a-fA-F]{6})")
	var groups := 0
	var values := 0
	for m in re.search_all(block):
		var g := m.get_string(1)
		for p in pair.search_all(m.get_string(2)):
			var want := p.get_string(2).hex_to_int()
			var got := DmFxData.spell(g, p.get_string(1))
			var exp := DmFxData.hex(want)
			check(got.is_equal_approx(exp), "SPELL_FX.%s.%s = %s" % [g, p.get_string(1), p.get_string(2)])
			values += 1
		groups += 1
	check(groups >= 28 and values >= 100, "parsed %d groups, %d colours" % [groups, values])
	# Presets carry the SPELL_FX colour (spell colour keeps its meaning).
	check(DmFxData.preset("miasma_cloud")["colors"][0].is_equal_approx(DmFxData.spell("miasma", "rot")), "miasma_cloud preset = miasma.rot")
	check(DmFxData.preset("corpse_explosion")["colors"][2].is_equal_approx(DmFxData.spell("detonate", "crimson")), "corpse_explosion preset = detonate.crimson")
	check(DmFxData.preset("litany_pulse")["colors"][0].is_equal_approx(DmFxData.spell("litany", "core")), "litany preset = litany.core")
	check(DmFxData.preset("soul_harvest_pillar")["colors"][0].is_equal_approx(DmFxData.spell("souls", "jade")), "soul harvest preset = souls.jade")
	check(DmFxData.preset("exhume_lift")["colors"][0].is_equal_approx(DmFxData.spell("exhume", "spirit")), "exhume preset = exhume.spirit")
	check(DmFxData.preset("dirge_area")["colors"][0].is_equal_approx(DmFxData.spell("dirge", "frost")), "dirge preset = dirge.frost")
	check(DmFxData.preset("grave_step_smoke")["colors"][0].is_equal_approx(DmFxData.spell("step", "mist")), "grave step preset = step.mist")
	check(is_equal_approx(float(DmFxData.preset("miasma_cloud")["scale"]), 1.0) and is_equal_approx(float(DmFxData.preset("needle_hit")["scale"]), 0.4), "preset scales")
	# Every preset id is a real effect.
	for id in DmFxData.data()["presets"]:
		check(ResourceLoader.exists("res://assets/fx/binbun/%s.tscn" % id), "preset %s has a scene" % id)


func _test_json_match() -> void:
	# Lifetimes and animation lengths of the rebuilt scenes equal the converted JSON they came from.
	for id in DmFxData.catalog("effects"):
		var j: Variant = JSON.parse_string(_read("res://../public/fx/binbun/%s.json" % id))
		if not (j is Dictionary):
			check(false, "%s json readable" % id)
			continue
		var doc: Dictionary = j["documents"][j["root"]]
		var want_life: Array = []
		var anim_len := -1.0
		var anim_name := String(j["animation"])
		var nested := false
		for s in doc["sections"]:
			if s["kind"] == "node" and s["attributes"].has("instance"):
				nested = true
			if s["kind"] == "node" and s["attributes"].get("type", "") == "GPUParticles3D":
				want_life.append(snappedf(float(s["properties"].get("lifetime", 1.0)), 0.0001))
		var scene := load("res://assets/fx/binbun/%s.tscn" % id) as PackedScene
		var root := scene.instantiate()
		var got_life: Array = []
		var ap: AnimationPlayer = null
		var stack: Array = [root]
		while not stack.is_empty():
			var c: Node = stack.pop_back()
			if c is GPUParticles3D:
				got_life.append(snappedf((c as GPUParticles3D).lifetime, 0.0001))
			if c is AnimationPlayer:
				ap = c
			stack.append_array(c.get_children())
		want_life.sort()
		got_life.sort()
		if nested:
			# A nested PackedScene (fire sparks) adds its own emitters: the converted ones must all be present.
			var pool := got_life.duplicate()
			var all_in := true
			for v in want_life:
				var idx := pool.find(v)
				if idx < 0:
					all_in = false
				else:
					pool.remove_at(idx)
			check(all_in, "%s lifetimes %s within %s" % [id, str(want_life), str(got_life)])
		else:
			check(want_life == got_life, "%s particle lifetimes %s == %s" % [id, str(want_life), str(got_life)])
		if ap != null and ap.has_animation(anim_name):
			anim_len = ap.get_animation(anim_name).length
		var info := DmFxData.effect_info(id)
		if anim_len >= 0.0 and float(j["duration"]) > 0.0:
			check(absf(anim_len - float(j["duration"])) < 0.001 or anim_name == "main", "%s animation %s length %.3f vs duration %.3f" % [id, anim_name, anim_len, float(j["duration"])])
		check(absf(float(info.get("duration", -1)) - float(j["duration"])) < 0.0001, "%s fx_data duration == json" % id)
		root.free()


func _world() -> Dictionary:
	var fx := DmFxRuntime.new()
	root.add_child(fx)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 12, 9)
	cam.look_at(Vector3.ZERO)
	return {"fx": fx, "cam": cam}


func _test_caps() -> void:
	var w := _world()
	var fx: DmFxRuntime = w["fx"]
	await process_frame
	check(fx.binbun != null and fx.prims != null, "runtime built")
	var caps := DmFxData.caps()
	check(int(caps["max_oneshots"]) == 24 and int(caps["max_loopers"]) == 32, "binbun caps 24 / 32")
	check(int(caps["combat_transients"]) == 160 and int(caps["additive_particles"]) == 3500 and int(caps["smoke_particles"]) == 900, "effects caps 160 / 3500 / 900")
	# Caps are the constants in the web source.
	var src := _read("res://../src/graphics/binbun/BinbunFX.ts")
	check(src.contains("const MAX_ONESHOTS = %d" % int(caps["max_oneshots"])) and src.contains("const MAX_LOOPERS = %d" % int(caps["max_loopers"])), "caps match BinbunFX.ts")
	# 40 one-shots: only 24 stay live (the oldest are evicted).
	for i in 40:
		fx.play("miasma_cloud", Vector3(i, 0, 0), {})
	var live_one := 0
	for l in fx.binbun._live:
		if l.inst != null and not l.dead and not l.looping:
			live_one += 1
	check(live_one == 24, "one-shot cap: %d live" % live_one)
	await process_frame
	fx.clear()
	await process_frame
	# 40 loopers: only 32 materialise, the rest are dropped.
	var handles: Array = []
	for i in 40:
		handles.append(fx.play("brazier_fire", Vector3(i, 0, 0), {"duration": 30.0}))
	var live_loop := 0
	for l in fx.binbun._live:
		if l.inst != null and not l.dead and l.looping:
			live_loop += 1
	check(live_loop == 32, "looper cap: %d live" % live_loop)
	var alive := 0
	for h in handles:
		if h.alive:
			alive += 1
	check(alive == 32, "dropped loopers are dead handles (%d alive)" % alive)
	fx.clear()
	# 200 combat decals: the transient pool stays at 160; persistent ones are not counted.
	for i in 200:
		fx.decal({"tex": "ring", "color": 0xffffff, "x": i, "z": 0, "r": 1, "duration": 5})
	check(fx.transient_load() == 160, "combat transient cap: %d" % fx.transient_load())
	fx.decal({"tex": "ring", "color": 0xffffff, "x": 0, "z": 0, "r": 1, "duration": 5, "persistent": true})
	check(fx.transient_load() == 160, "persistent decals are outside the cap")
	# Graphics: Low has no Binbun layer.
	fx.quality = "low"
	var dead := fx.play("miasma_cloud", Vector3.ZERO, {})
	check(not dead.alive, "quality low: binbun play is a dead handle")
	fx.quality = "high"
	check(fx.play("miasma_cloud", Vector3.ZERO, {}).alive, "quality high: binbun plays")
	# Unknown id never throws.
	check(not fx.play("no_such_effect", Vector3.ZERO, {}).alive, "unknown id is a dead handle")
	# Handles: kill ends it, preset scale/alpha multiply.
	var h2 := fx.play("brazier_fire", Vector3.ZERO, {"scale": 2.0})
	var lv: DmFxBinbun.Live = h2
	check(is_equal_approx(float(lv.opts["scale"]), 0.8), "preset scale 0.4 * 2")
	check(is_equal_approx(float(lv.opts["alpha"]), 0.9), "preset alpha 0.9")
	h2.kill()
	check(lv.fading >= 0.0, "kill starts the fade")
	# Partner dimming.
	fx.role = "other"
	var h3 := fx.play("litany_pulse", Vector3.ZERO, {})
	var l3: DmFxBinbun.Live = h3
	check(is_equal_approx(float(l3.opts["alpha"]), 0.9 * 0.35) and is_equal_approx(float(l3.opts["scale"]), 0.75), "partner binbun dimmed (0.35 alpha, 0.75 scale)")
	fx.role = "self"
	w["fx"].queue_free()
	w["cam"].queue_free()
	await process_frame


func _test_prims() -> void:
	var w := _world()
	var fx: DmFxRuntime = w["fx"]
	await process_frame
	fx.emit({"x": 0, "y": 0, "z": 0, "count": 100, "color": 0xff0000})
	check(fx.prims.additive.active() == 100, "emit 100 -> 100 active")
	fx.particle_scale = 0.5
	fx.emit({"x": 0, "y": 0, "z": 0, "count": 10, "color": 0xff0000})
	check(fx.prims.additive.active() == 105, "particle_scale 0.5 -> 5 more")
	fx.particle_scale = 1.0
	fx.quality = "low"
	fx.emit({"x": 0, "y": 0, "z": 0, "count": 4, "color": 0xff0000})
	check(fx.prims.additive.active() == 108, "low quality keeps 3/4 (round(4*0.75)=3)")
	fx.quality = "high"
	fx.emit_smoke({"x": 0, "y": 0, "z": 0, "count": 7, "color": 0x303030})
	check(fx.prims.smoke.active() == 7, "smoke ring")
	# Ring capacity: 4000 emits never exceed 3500 live.
	fx.emit({"x": 0, "y": 0, "z": 0, "count": 4000, "color": 0xff0000, "life": 5.0})
	check(fx.prims.additive.active() <= 3500, "additive ring capped at 3500 (%d)" % fx.prims.additive.active())
	for i in 40:
		await process_frame
	# Motes expire.
	fx.prims.additive.update(100.0)
	check(fx.prims.additive.active() == 0, "motes expire")
	# Handles.
	var d := fx.decal({"tex": "disc", "color": 0xff0000, "x": 0, "z": 0, "r": 2, "duration": 1.0})
	check(d.alive, "decal alive")
	d.kill()
	check(not d.alive, "decal kill")
	# Danger decals are drawn on the highest layer; a normal one on the friendly layer.
	fx.danger(func(): fx.decal({"tex": "ring", "color": 0xff0000, "x": 0, "z": 0, "r": 2, "duration": 1.0}))
	var keys: Array = fx.prims._decal_layers.keys()
	var has_danger := false
	for k in keys:
		if String(k).ends_with("|4"):
			has_danger = true
	check(has_danger, "danger() routes decals to order 4")
	# Projectile lands and calls back.
	var landed := [false]
	var ref := fx.projectile({"from": Vector3.ZERO, "to": func(): return Vector3(3, 1, 0), "speed": 30.0, "color": 0xffffff, "kind": "orb", "on_arrive": func(_p): landed[0] = true})
	check(ref.pos() != null, "projectile in flight")
	for i in 30:
		await process_frame
	check(landed[0] and ref.pos() == null, "projectile landed + on_arrive")
	# Motif budget: a thrall asks for 40 % and may get zero; the budget never goes negative.
	fx.motifs.reset_budget()
	var before: int = fx.motifs.stats["particles"]
	fx.motifs.bone_splinters(0, 1, 0, {"n": 5})
	check(int(fx.motifs.stats["particles"]) - before == 5, "motif grants 5 bone splinters at full budget")
	fx.quality = "low"
	var b2: int = fx.motifs.stats["particles"]
	fx.motifs.bone_splinters(0, 1, 0, {"n": 5})
	check(int(fx.motifs.stats["particles"]) == b2, "motifs are off on Graphics: Low")
	fx.quality = "high"
	fx.reduced_motion = true
	check(is_equal_approx(fx.motifs.scale("player"), 0.4) and is_equal_approx(fx.motifs.scale("thrall"), 0.16), "reduced motion 0.4, thrall 0.4*0.4")
	fx.reduced_motion = false
	fx.motifs.reset_budget()
	var drained := 0
	for i in 100:
		fx.motifs.bone_splinters(0, 1, 0, {"n": 20})
		drained = int(fx.motifs.stats["particles"])
	check(drained <= 240 + 40, "motif particle budget caps the burst (%d)" % drained)
	w["fx"].queue_free()
	w["cam"].queue_free()
	await process_frame
