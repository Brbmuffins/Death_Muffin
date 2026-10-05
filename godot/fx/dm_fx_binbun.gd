class_name DmFxBinbun
extends RefCounted
## Plays the rebuilt native BinbunVFX scenes (res://assets/fx/binbun/<id>.tscn, made by tools/godot/fx-binbun-rebuild.ts) with the
## same rules as the web's BinbunFX.ts: capped (24 one-shots, 32 loopers), pooled per effect id, loopers culled when far or
## off-screen, spawn colours win over the scene's own, `once` plays an impact's looping animation a single time, `follow` /
## `duration` / `alpha` / `scale` / `rot` as in BinbunSpawn. OmniLight3D nodes are never lit natively: the first one of a
## one-shot goes through the manager's single shared flash light, like Effects.lightFlash.

const BASE := "res://assets/fx/binbun/"
const KEYS := ["primary_color", "secondary_color", "tertiary_color"]
const POOL_MAX := 4

var enabled := true
## Hitstop / slow-mo: scales animation + particle speed (the web scales dt by hitstop.scale).
var time_scale := 1.0
## Global brightness multiplier pushed into every shader (dm_gain). 1 = the original Godot look; the web ran 0.5 with a soft knee.
var gain := 1.0
## flash(pos: Vector3, color: Color, intensity: float, life: float) -> void
var flash_cb: Callable

var _host: Node3D
var _scenes: Dictionary = {}
var _pool: Dictionary = {}
var _live: Array = []
var _clock := 0.0
var _caps := DmFxData.caps()
var _built: Array = []


class Inst:
	var id := ""
	var root: Node3D
	var ctrl: DmFxController
	var mats: Array = []
	var names: Array = []
	var base_depth: Array = []
	var std_mats: Array = []
	var particles: Array = []
	var emit_default: Array = []
	var meshes: Array = []
	var players: Array = []
	var lights: Array = []
	var light_peaks: Array = []
	var longest := 0.0
	var all_oneshot := true
	var has_anim := false
	var anim_name := ""
	var anim_res_name := ""
	var anim_len := 0.0
	var anim_loops := false
	var fade_cache := -1.0
	var gain_cache := -1.0
	var ap: AnimationPlayer


class Live:
	extends DmFxHandle
	var id := ""
	var opts: Dictionary = {}
	var inst: Inst
	var t := 0.0
	var end := INF
	var fading := -1.0
	var dead := false
	var looping := false
	var culled := false
	var alpha_mul := 1.0
	var pos := Vector3.ZERO
	var follow: Callable
	var stopped_at := -1.0

	func is_alive() -> bool:
		return not dead

	func kill() -> void:
		if dead:
			return
		if inst == null:
			dead = true
		elif fading < 0.0:
			fading = 0.0

	func move(p: Vector3) -> void:
		pos = p

	func set_alpha(a: float) -> void:
		alpha_mul = a


func _init(host: Node3D) -> void:
	_host = host


## Number of effects playing (QA).
func count() -> int:
	var n := 0
	for l in _live:
		if not l.dead:
			n += 1
	return n


func has_scene(id: String) -> bool:
	return _scene(id) != null


func _scene(id: String) -> PackedScene:
	if _scenes.has(id):
		return _scenes[id]
	var path := BASE + id + ".tscn"
	var s: PackedScene = null
	if ResourceLoader.exists(path):
		s = load(path) as PackedScene
	_scenes[id] = s
	return s


## Load (and cache) the scenes ahead of their first play.
func preload_ids(ids: Array) -> void:
	for id in ids:
		_scene(String(id))


## Play an effect. Never throws: an unknown id or a disabled system is a dead handle.
## o: colors (Array of Color/int), scale, rot (yaw), follow (Callable -> Vector3 or null), duration, once, alpha.
func spawn(id: String, pos: Vector3, o: Dictionary = {}) -> DmFxHandle:
	var live := Live.new()
	live.id = id
	live.opts = o
	live.pos = pos
	live.alpha_mul = float(o.get("alpha", 1.0))
	if o.has("follow") and o["follow"] is Callable:
		live.follow = o["follow"]
	var scene := _scene(id) if enabled else null
	if scene == null:
		live.dead = true
		return live
	_live.append(live)
	_materialize(live)
	return live


func _is_looping(inst: Inst, o: Dictionary, duration: float) -> bool:
	if o.get("once", false):
		return false
	if inst.has_anim and not inst.anim_loops:
		return false
	if not inst.has_anim and duration > 0.0 and inst.all_oneshot:
		return false
	return not (inst.has_anim and inst.anim_res_name == "oneshot")


func _materialize(live: Live) -> void:
	var info := DmFxData.effect_info(live.id)
	var pooled: Array = _pool.get(live.id, [])
	var inst: Inst = pooled.pop_back() if not pooled.is_empty() else _build(live.id)
	if inst == null:
		live.dead = true
		return
	var o := live.opts
	var duration := float(info.get("duration", 0.0))
	var looping := _is_looping(inst, o, duration)
	# Caps: loopers over the cap are dropped, one-shots evict the oldest one-shot.
	var kind: Array = []
	for l in _live:
		if l != live and l.inst != null and not l.dead and l.looping == looping:
			kind.append(l)
	var cap := int(_caps.get("max_loopers" if looping else "max_oneshots", 24))
	if kind.size() >= cap:
		if looping:
			live.dead = true
			_stash(inst)
			return
		_release(kind[0])
	live.inst = inst
	live.looping = looping
	var once: bool = o.get("once", false)
	if o.has("duration"):
		live.end = float(o["duration"])
	elif not looping:
		live.end = maxf(maxf(0.0 if once else inst.anim_len, duration), inst.longest + (0.0 if once else 0.05)) + 0.05
	# Colours: spawn colours win, else the file's defaults, else each material keeps its own.
	var cols := _palette(o.get("colors", _default_colors(info)))
	_host.add_child(inst.root)
	_reset(inst)
	inst.root.visible = true
	inst.root.position = live.pos
	inst.root.rotation = Vector3(0.0, float(o.get("rot", 0.0)), 0.0)
	inst.root.scale = Vector3.ONE * float(o.get("scale", 1.0))
	if not cols.is_empty():
		_apply_colors(inst, cols)
	inst.fade_cache = -1.0
	inst.gain_cache = -1.0
	_push_fade(inst, live.alpha_mul)
	for i in inst.particles.size():
		(inst.particles[i] as GPUParticles3D).emitting = inst.emit_default[i]
	if inst.has_anim and inst.ap != null:
		inst.ap.speed_scale = time_scale
		inst.ap.play(inst.anim_name)
	# One shared light flash through the manager (one-shots only; loopers stay unlit).
	if not looping and flash_cb.is_valid() and not inst.lights.is_empty():
		var l0: DmFxLight = inst.lights[0]
		var peak: float = inst.light_peaks[0]
		var c: Color = cols[0] if not cols.is_empty() else l0.light_color
		var off := l0.global_position - inst.root.global_position
		var life := minf(0.9, maxf(0.25, inst.anim_len * 0.6 if inst.anim_len > 0.0 else 0.4))
		flash_cb.call(live.pos + off + Vector3(0, 0.6, 0), c, minf(8.0, l0.peak_energy() * peak * 1.2), life)


func _default_colors(info: Dictionary) -> Array:
	var out: Array = []
	for c in info.get("defaultColors", []):
		out.append(DmFxData.to_color(c))
	return out


## [primary, secondary?, tertiary?] -> 3 Colors; missing entries darken from the last (0.55 in linear space, like the web).
func _palette(src: Variant) -> Array:
	var out: Array = []
	if not (src is Array) or (src as Array).is_empty():
		return out
	for c in (src as Array).slice(0, 3):
		out.append(DmFxData.to_color(c))
	while out.size() < 3:
		var last: Color = out[out.size() - 1]
		var lin := last.srgb_to_linear()
		var dark := Color(lin.r * 0.55, lin.g * 0.55, lin.b * 0.55, last.a).linear_to_srgb()
		out.append(dark)
	return out


func _apply_colors(inst: Inst, cols: Array) -> void:
	for i in inst.mats.size():
		var m: ShaderMaterial = inst.mats[i]
		for k in 3:
			if inst.names[i].has(KEYS[k]):
				m.set_shader_parameter(KEYS[k], cols[k])
	var p: Color = cols[0]
	for e in inst.std_mats:
		var sm: StandardMaterial3D = e[0]
		var orig: Color = e[1]
		var top := maxf(maxf(p.r, p.g), maxf(p.b, 0.001))
		var k2 := maxf(maxf(orig.r, orig.g), orig.b) / top
		sm.albedo_color = Color(p.r * k2, p.g * k2, p.b * k2, orig.a)


func _push_fade(inst: Inst, f: float) -> void:
	if absf(f - inst.fade_cache) < 0.0005:
		return
	inst.fade_cache = f
	for i in inst.mats.size():
		if inst.names[i].has("dm_fade"):
			(inst.mats[i] as ShaderMaterial).set_shader_parameter("dm_fade", f)


func _push_gain(inst: Inst) -> void:
	if absf(gain - inst.gain_cache) < 0.0005:
		return
	inst.gain_cache = gain
	for i in inst.mats.size():
		if inst.names[i].has("dm_gain"):
			(inst.mats[i] as ShaderMaterial).set_shader_parameter("dm_gain", gain)


# --- building ---------------------------------------------------------------------------------------------------------

func _build(id: String) -> Inst:
	var scene := _scene(id)
	if scene == null:
		return null
	var root := scene.instantiate() as Node3D
	if root == null:
		return null
	var inst := Inst.new()
	inst.id = id
	inst.root = root
	inst.ctrl = root as DmFxController
	var drop: Array = []
	_walk(inst, root, drop)
	for n in drop:
		(n as Node).get_parent().remove_child(n)
		(n as Node).queue_free()
	if inst.ctrl != null:
		inst.ctrl.bind(inst.mats, inst.names)
	var info := DmFxData.effect_info(id)
	var want := String(info.get("animation", "main"))
	for ap in inst.players:
		var a: AnimationPlayer = ap
		var name := want
		if not a.has_animation(name):
			name = "main" if a.has_animation("main") else ("oneshot" if a.has_animation("oneshot") else "")
		if name == "":
			continue
		var anim: Animation = a.get_animation(name)
		inst.has_anim = true
		inst.ap = a
		inst.anim_name = name
		inst.anim_res_name = String(anim.resource_name) if String(anim.resource_name) != "" else name
		inst.anim_len = anim.length
		inst.anim_loops = anim.loop_mode != Animation.LOOP_NONE
		a.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
		for li in inst.lights.size():
			var light: DmFxLight = inst.lights[li]
			var rel := String(root.get_path_to(light))
			var peak := 0.0
			for ti in anim.get_track_count():
				var tp := String(anim.track_get_path(ti))
				if tp.ends_with(":light_multiplier") and (tp.begins_with(light.name + ":") or tp.begins_with(rel + ":")):
					for ki in anim.track_get_key_count(ti):
						peak = maxf(peak, float(anim.track_get_key_value(ti, ki)))
			inst.light_peaks[li] = peak if peak > 0.0 else 1.0
		break
	_built.append(inst)
	return inst


func _walk(inst: Inst, n: Node, drop: Array) -> void:
	if n is AudioStreamPlayer3D:
		drop.append(n)
		return
	if n is GPUParticles3D:
		var p := n as GPUParticles3D
		# ShadowCaster emitters (transparency 1, only there to cast shadows) would draw as solid white without shadows.
		if p.is_in_group("ShadowCaster") or p.transparency >= 0.99 or p.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			drop.append(n)
			return
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if p.visibility_aabb.size.length() < 7.0:
			p.visibility_aabb = AABB(Vector3(-6, -3, -6), Vector3(12, 9, 12))
		inst.particles.append(p)
		inst.emit_default.append(p.emitting)
		inst.longest = maxf(inst.longest, maxf(0.05, p.lifetime))
		if not p.one_shot:
			inst.all_oneshot = false
		_own_material(inst, p)
	elif n is MeshInstance3D:
		var mi := n as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.meshes.append(mi)
		_own_material(inst, mi)
	elif n is DmFxLight:
		inst.lights.append(n)
		inst.light_peaks.append(1.0)
	elif n is AnimationPlayer:
		inst.players.append(n)
	for c in n.get_children():
		_walk(inst, c, drop)


func _own_material(inst: Inst, gi: GeometryInstance3D) -> void:
	var m: Material = gi.material_override
	if m != null:
		m = m.duplicate()
		gi.material_override = m
	else:
		var mesh: Mesh = null
		if gi is MeshInstance3D:
			mesh = (gi as MeshInstance3D).mesh
		elif gi is GPUParticles3D:
			mesh = (gi as GPUParticles3D).draw_pass_1
		if mesh != null and mesh.get("material") is Material:
			var m2: Mesh = mesh.duplicate()
			m = (mesh.get("material") as Material).duplicate()
			m2.set("material", m)
			if gi is MeshInstance3D:
				(gi as MeshInstance3D).mesh = m2
			else:
				(gi as GPUParticles3D).draw_pass_1 = m2
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		sm.render_priority = 6
		var names := {}
		if sm.shader != null:
			for u in sm.shader.get_shader_uniform_list():
				names[String(u["name"])] = true
		inst.mats.append(sm)
		inst.names.append(names)
		var d: Variant = sm.get_shader_parameter("proximity_fade_distance")
		inst.base_depth.append(float(d) if d != null else -1.0)
	elif m is StandardMaterial3D:
		var std := m as StandardMaterial3D
		inst.std_mats.append([std, std.albedo_color])


func _reset(inst: Inst) -> void:
	for p in inst.particles:
		(p as GPUParticles3D).emitting = false
	if inst.ap != null:
		if inst.ap.has_animation("RESET"):
			inst.ap.play("RESET")
			inst.ap.advance(0.0)
		inst.ap.stop()
	for l in inst.lights:
		(l as DmFxLight).light_multiplier = 1.0


# --- per-frame -------------------------------------------------------------------------------------------------------

func update(dt: float, cam: Camera3D) -> void:
	_clock += dt
	if _live.is_empty():
		return
	var cam_pos := cam.global_position if cam != null else Vector3.ZERO
	var planes: Array[Plane] = []
	if cam != null:
		planes.assign(cam.get_frustum())
	var cull := float(_caps.get("cull_distance", 40)) + absf(cam_pos.y)
	var fade_out := float(_caps.get("fade_out", 0.3))
	for i in range(_live.size() - 1, -1, -1):
		var live: Live = _live[i]
		if live.dead:
			if live.inst != null:
				_release(live)
			_live.remove_at(i)
			continue
		var inst := live.inst
		if inst == null:
			_live.remove_at(i)
			continue
		if live.follow.is_valid():
			var at: Variant = live.follow.call()
			if at is Vector3:
				live.pos = at
			else:
				live.kill()
		live.t += dt * time_scale
		inst.root.position = live.pos
		var scale := float(live.opts.get("scale", 1.0))
		if live.looping:
			var far := Vector2(live.pos.x - cam_pos.x, live.pos.z - cam_pos.z).length() > cull
			var visible_in_frustum := true
			for pl in planes:
				if pl.distance_to(live.pos + Vector3(0, 1, 0)) > 4.0 * scale + 1.0:
					visible_in_frustum = false
					break
			live.culled = far or not visible_in_frustum
			inst.root.visible = not live.culled
			if live.culled:
				continue
		var natural_end := false
		if live.t >= live.end and live.fading < 0.0:
			if live.looping or live.opts.has("duration"):
				live.fading = 0.0
			else:
				natural_end = true
				live.fading = fade_out
		var fade := live.alpha_mul
		if live.fading >= 0.0:
			if not natural_end:
				live.fading += dt
			fade *= maxf(0.0, 1.0 - live.fading / fade_out)
			if live.stopped_at < 0.0:
				live.stopped_at = live.t
				for p in inst.particles:
					(p as GPUParticles3D).emitting = false
		# `once` plays the looping animation a single cycle, then holds.
		if inst.ap != null and live.opts.get("once", false) and live.t >= inst.anim_len and inst.ap.is_playing():
			inst.ap.pause()
		if inst.ap != null and absf(inst.ap.speed_scale - time_scale) > 0.001:
			inst.ap.speed_scale = time_scale
		var ctrl_fade := inst.ctrl.fade_mult if inst.ctrl != null else 1.0
		_push_fade(inst, fade * ctrl_fade)
		_push_gain(inst)
		if inst.ctrl != null and inst.ctrl.depth_mult != 1.0:
			for k in inst.mats.size():
				if inst.base_depth[k] >= 0.0 and inst.names[k].has("proximity_fade_distance"):
					(inst.mats[k] as ShaderMaterial).set_shader_parameter("proximity_fade_distance", float(inst.base_depth[k]) * inst.ctrl.depth_mult)
		if live.fading >= 0.0:
			var waited := live.t - live.stopped_at
			var wait := minf(inst.longest, 2.0) + (0.0 if natural_end else fade_out)
			if waited >= wait:
				_release(live)
				_live.remove_at(i)
		elif not live.looping and live.t >= live.end + 0.05:
			_release(live)
			_live.remove_at(i)


func _release(live: Live) -> void:
	live.dead = true
	var inst := live.inst
	live.inst = null
	if inst == null:
		return
	_stash(inst)


func _stash(inst: Inst) -> void:
	# The scene that hosted the effect may already be freed (e.g. the world was torn down while it played).
	if not is_instance_valid(inst.root):
		_built.erase(inst)
		return
	for p in inst.particles:
		if is_instance_valid(p):
			(p as GPUParticles3D).emitting = false
	if inst.root.get_parent() != null:
		inst.root.get_parent().remove_child(inst.root)
	var list: Array = _pool.get(inst.id, [])
	if list.size() < POOL_MAX:
		list.append(inst)
		_pool[inst.id] = list
	else:
		inst.root.queue_free()
		_built.erase(inst)


## Stop everything (area change / scene teardown keeps the pools).
func clear() -> void:
	for l in _live.duplicate():
		if l.inst != null:
			_release(l)
		l.dead = true
	_live.clear()


func dispose() -> void:
	clear()
	for inst in _built:
		var root: Node = (inst as Inst).root
		if is_instance_valid(root):
			# Pooled roots are orphans (no parent): free them now, before the rendering server shuts down at quit.
			if root.get_parent() == null:
				root.free()
			else:
				root.queue_free()
	_built.clear()
	_pool.clear()
