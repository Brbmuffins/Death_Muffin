extends SceneTree
## DmFx tests: godot --headless --path client --script res://tests/fx/run.gd
## Every effect id instantiates; animation lengths / particle lifetimes match the converted
## JSON; the caps of fx_data.json (one-shots, loopers, combat transients, particle rings) hold; the particle rings, roles and motif budget behave.

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
	await _test_sheets()
	print("%d passed, %d failed" % [passed, failed])
	print("%s fx %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


func _test_scenes() -> void:
	var ids: Array = DmFxData.catalog("effects")
	check(not ids.is_empty(), "catalog has %d spawnable effects" % ids.size())
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
	# Presets carry the SPELL_FX colour (spell colour keeps its meaning).
	check(DmFxData.preset("miasma_cloud")["colors"][0].is_equal_approx(DmFxData.spell("miasma", "rot")), "miasma_cloud preset = miasma.rot")
	check(DmFxData.preset("corpse_explosion")["colors"][2].is_equal_approx(DmFxData.spell("detonate", "crimson")), "corpse_explosion preset = detonate.crimson")
	check(DmFxData.preset("litany_pulse")["colors"][0].is_equal_approx(DmFxData.spell("litany", "core")), "litany preset = litany.core")
	check(DmFxData.preset("soul_harvest_pillar")["colors"][0].is_equal_approx(DmFxData.spell("souls", "jade")), "soul harvest preset = souls.jade")
	check(DmFxData.preset("exhume_lift")["colors"][0].is_equal_approx(DmFxData.spell("exhume", "spirit")), "exhume preset = exhume.spirit")
	check(DmFxData.preset("dirge_area")["colors"][0].is_equal_approx(DmFxData.spell("dirge", "frost")), "dirge preset = dirge.frost")
	check(DmFxData.preset("grave_step_smoke")["colors"][0].is_equal_approx(DmFxData.spell("step", "mist")), "grave step preset = step.mist")
	check(float(DmFxData.preset("miasma_cloud")["scale"]) > 0.0 and float(DmFxData.preset("needle_hit")["scale"]) > 0.0, "preset scales")
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
	var one_cap := int(caps["max_oneshots"])
	var loop_cap := int(caps["max_loopers"])
	var transient_cap := int(caps["combat_transients"])
	var additive_cap := int(caps["additive_particles"])
	check(one_cap > 0 and loop_cap > 0 and transient_cap > 0 and additive_cap > 0 and int(caps["smoke_particles"]) > 0, "the caps of the data are all there (%d one-shots, %d loopers, %d transients, %d / %d particles)" % [one_cap, loop_cap, transient_cap, additive_cap, int(caps["smoke_particles"])])
	# more one-shots than the cap: only the cap's worth stay live (the oldest are evicted).
	for i in one_cap + 16:
		fx.play("miasma_cloud", Vector3(i, 0, 0), {})
	var live_one := 0
	for l in fx.binbun._live:
		if l.inst != null and not l.dead and not l.looping:
			live_one += 1
	check(live_one == one_cap, "one-shot cap: %d live of %d" % [live_one, one_cap])
	await process_frame
	fx.clear()
	await process_frame
	# more loopers than the cap: only the cap's worth materialise, the rest are dropped.
	var handles: Array = []
	for i in loop_cap + 8:
		handles.append(fx.play("brazier_fire", Vector3(i, 0, 0), {"duration": 30.0}))
	var live_loop := 0
	for l in fx.binbun._live:
		if l.inst != null and not l.dead and l.looping:
			live_loop += 1
	check(live_loop == loop_cap, "looper cap: %d live of %d" % [live_loop, loop_cap])
	var alive := 0
	for h in handles:
		if h.alive:
			alive += 1
	check(alive == loop_cap, "dropped loopers are dead handles (%d alive)" % alive)
	fx.clear()
	# more combat decals than the cap: the transient pool stays at the cap; persistent ones are not counted.
	for i in transient_cap + 40:
		fx.decal({"tex": "ring", "color": 0xffffff, "x": i, "z": 0, "r": 1, "duration": 5})
	check(fx.transient_load() == transient_cap, "combat transient cap: %d of %d" % [fx.transient_load(), transient_cap])
	fx.decal({"tex": "ring", "color": 0xffffff, "x": 0, "z": 0, "r": 1, "duration": 5, "persistent": true})
	check(fx.transient_load() == transient_cap, "persistent decals are outside the cap")
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
	var brazier := DmFxData.preset("brazier_fire")
	check(is_equal_approx(float(lv.opts["scale"]), float(brazier["scale"]) * 2.0), "preset scale x the asked 2")
	check(is_equal_approx(float(lv.opts["alpha"]), float(brazier["alpha"])), "preset alpha")
	h2.kill()
	check(lv.fading >= 0.0, "kill starts the fade")
	# Partner dimming.
	fx.role = "other"
	var h3 := fx.play("litany_pulse", Vector3.ZERO, {})
	var l3: DmFxBinbun.Live = h3
	var litany := DmFxData.preset("litany_pulse")
	check(is_equal_approx(float(l3.opts["alpha"]), float(litany["alpha"]) * float(caps["other_binbun_alpha"])) and is_equal_approx(float(l3.opts["scale"]), float(litany["scale"]) * float(caps["other_binbun_scale"])), "partner binbun dimmed (the caps' other_binbun_alpha and other_binbun_scale)")
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
	var low_n := roundi(4.0 * float(DmFxData.caps()["low_particle_scale"]))
	check(fx.prims.additive.active() == 105 + low_n, "low quality keeps its share (round(4 x low_particle_scale) = %d)" % low_n)
	fx.quality = "high"
	fx.emit_smoke({"x": 0, "y": 0, "z": 0, "count": 7, "color": 0x303030})
	check(fx.prims.smoke.active() == 7, "smoke ring")
	# Ring capacity: more emits than the ring holds never exceed it.
	var ring_cap := int(DmFxData.caps()["additive_particles"])
	fx.emit({"x": 0, "y": 0, "z": 0, "count": ring_cap + 500, "color": 0xff0000, "life": 5.0})
	check(fx.prims.additive.active() <= ring_cap, "additive ring capped at %d (%d)" % [ring_cap, fx.prims.additive.active()])
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
	# A hovering shot (the Reaper's soul wisp) loops round where it started for `hover` seconds, then flies to its target and lands.
	var hlanded := [false]
	var hover_s := 0.0   # game time (headless frames are not real time): the per-frame deltas added up
	var href := fx.projectile({"from": Vector3.ZERO, "to": func(): return Vector3(30, 1, 0), "speed": 60.0, "color": 0xffffff, "kind": "orb", "hover": 0.4, "hover_r": 0.9, "on_arrive": func(_p): hlanded[0] = true})
	await process_frame
	hover_s += root.get_process_delta_time()
	var hp: Variant = href.pos()
	check(hp != null and not hlanded[0] and (hp as Vector3).length() < 2.0, "hovering projectile stays near where it started")
	var hover_guard := 0
	while not hlanded[0] and hover_guard < 600:
		await process_frame
		hover_s += root.get_process_delta_time()
		hover_guard += 1
	check(hlanded[0] and href.pos() == null and hover_s >= 0.38, "hovering projectile lands only after its hover time (%.2f s)" % hover_s)
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
	var mcaps := DmFxData.caps()
	check(is_equal_approx(fx.motifs.scale("player"), float(mcaps["motif_reduced_scale"])) and is_equal_approx(fx.motifs.scale("thrall"), float(mcaps["motif_reduced_scale"]) * float(mcaps["motif_thrall_scale"])), "reduced motion scales motifs, and a thrall's share of that")
	fx.reduced_motion = false
	fx.motifs.reset_budget()
	var drained := 0
	for i in 100:
		fx.motifs.bone_splinters(0, 1, 0, {"n": 20})
		drained = int(fx.motifs.stats["particles"])
	var burst := int(mcaps["motif_particle_burst"])
	check(drained <= burst + 40, "motif particle budget caps the burst (%d of %d)" % [drained, burst])
	w["fx"].queue_free()
	w["cam"].queue_free()
	await process_frame


## Flipbook sheets (fx_data.json `sheets`; the PNGs are outside git, tools/godot/fx-sheets-sync.sh): valid grids; when installed, a flash / decal
## of a sheet draws through the sheet shader and steps its frame with the effect's life (a looping sheet wraps); when missing, no texture.
func _test_sheets() -> void:
	var sheets: Dictionary = DmFxData.data().get("sheets", {})
	check(not sheets.is_empty(), "sheets listed")
	for id: String in sheets:
		var sh: Dictionary = sheets[id]
		check(int(sh["cols"]) * int(sh["rows"]) >= int(sh["frames"]) and float(sh["fps"]) > 0.0, "%s: grid holds its frames" % id)
		var installed := FileAccess.file_exists(DmFxTex.SHEET_DIR + id + ".png")
		check(DmFxTex.has_sheet(id) == installed, "%s: has_sheet matches the file (%s)" % [id, installed])
	if not DmFxTex.has_sheet("hit_flash") or not DmFxTex.has_sheet("summon_circle"):
		print("INFO sheets not installed: shader/frame checks skipped (tools/godot/fx-sheets-sync.sh)")
		return
	var w := _world()
	var fx: DmFxRuntime = w["fx"]
	await process_frame
	var h := fx.flash({"tex": "hit_flash", "x": 0, "y": 1, "z": 0, "color": 0xffffff, "size": 2.0, "duration": 1.0})
	var tr: DmFxPrims.FlashTr = h.get("tr")   # `.tr` would be Object.tr()
	check(tr.sheet and (tr.layer._mat as ShaderMaterial).shader == DmFxTex.shader("sprite_sheet", true), "sheet flash uses the sprite sheet shader")
	var hf: Dictionary = sheets["hit_flash"]
	check((tr.layer._mat as ShaderMaterial).get_shader_parameter("grid") == Vector2(float(hf["cols"]), float(hf["rows"])), "sheet grid on the material")
	fx.prims.update(0.5, 0.5)
	check(is_equal_approx(tr.s.frame, 0.5) and is_equal_approx(tr.s.sx, 2.0), "sheet flash: frame follows its life at full size (%.2f)" % tr.s.frame)
	# (the old game's sheet decal checks, DmFxPrims.DecalTr, left with the decals' move to the core's C++ DmDecals: tests/fx_decals.gd holds their sheets)
	h.kill()
	fx.queue_free()
	(w["cam"] as Node).queue_free()
