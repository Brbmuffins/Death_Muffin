class_name DmCreature
extends RefCounted
## One animated instance of a model (port of archive/legacy-web:src/graphics/Creature.ts onto Godot): model + AnimationPlayer (advanced by hand, so the
## view layer can LOD / hitstop it like the web's mixer.update(dt)), the web's material options (tint, emissive, spectral, wings, rim,
## gear tint), stride-matched locomotion, timed strikes, one-shots, flinch, death/landing, hand props with the web's calibration + follow.
## Model rows (url, height, yaw, clips, timings, stride) come from godot/game/view_models.json (the retired web game\'s export-view-models exporter).
##
## Differences from the three.js version (deliberate, Godot has no equivalent): the flinch is a short replacing hurt clip (only when
## nothing else plays) instead of an additive layer; crossfades are the AnimationPlayer blend; the rim/gear/wings are one custom shader.

const FADE_LOCOMOTION := 0.28
const FADE_RETURN := 0.2
const IDLE_STAND_IN := 0.2
const FLINCH_SECONDS := 0.5
const FLINCH_SPEED := 1.35
const FLASH_LEVELS := 8
const FLASH_COLOR := 0xfff0dc
const COMBAT := ["slam", "sweep", "flick", "channel", "summon"]
const GEAR_REGIONS := ["chest", "legs", "hands", "feet"]
const FALLBACK := {
	"idle": ["idle", "walk"], "walk": ["walk", "run", "idle"], "run": ["run", "walk", "idle"],
	"attack": ["attack", "cast", "hurt"], "cast": ["cast", "attack", "hurt"], "hurt": ["hurt"], "death": ["death"],
	"dig": ["dig", "cast", "attack"], "chop": ["chop", "attack", "dig"], "dive": ["dive", "attack", "cast"],
	"talk": ["talk", "idle"], "talk2": ["talk2", "talk", "idle"],
	"slam": ["slam", "attack", "cast"], "sweep": ["sweep", "attack", "cast"], "flick": ["flick", "cast", "attack"],
	"channel": ["channel", "cast", "attack"], "summon": ["summon", "dig", "cast"],
}

static var _rows: Dictionary = {}
static var _landings: Dictionary = {}
## The picture clock of a struck enemy (hitstop.scale): the views copy Vfx.hitstop_scale here every frame.
static var hitstop_scale := 1.0

var root: Node3D
var slug: String
var rig_slug: String
var entry: Dictionary
var opts: Dictionary
var ap: AnimationPlayer
var skeleton: Skeleton3D
var loaded := false
var toppled := 0.0
var steady_every := 1
var last_plan: Dictionary = {}
var base_height := 1.0

var _model: Node3D
var _meshes: Array = []        # [{mi: MeshInstance3D, surf: int, op: ShaderMaterial, fade: ShaderMaterial or null, src: Material}]
var _params: Dictionary = {}
var _use_fade := false
var _opacity := 1.0
var _spectral := false
var _wings := false
var _gear := false
var _cull_back := false
var _shadow_on := true
var _disposed := false
var _em_base := Vector3.ZERO
var _em_k := 0.0
var _flash_v := 0.0
var _flash_level := 0
var _gear_tint: Array = []     # 4 x Vector4
var _gear_glow: Array = []     # 4 x Vector3
var _head_tint := Vector4(1, 1, 1, 0)
var _head_glow := Vector3.ZERO
# animation state
var _loop := "idle"
var _loop_speed := 1.0
var _current := ""
var _one_shot := ""
var _one_shot_end := -1.0
var _death_clip := ""
var _loco_run := false
var _last_ground := -1.0
var _flinch_t := -1.0
var _settled_t := 0.0
var _recheck_t := 0.0
var _steady_n := 0
var _fade_loco := FADE_LOCOMOTION
# props
var _pending: Array = []       # [bone, obj, dir, follow, fit]
var _attached: Array = []      # {obj, att, dir, follow, base_q, fit, calibrating}
var _after_load: Array = []


static func rows() -> Dictionary:
	if _rows.is_empty():
		var f := FileAccess.open("res://game/view_models.json", FileAccess.READ)
		if f != null:
			var v: Variant = JSON.parse_string(f.get_as_text())
			if v is Dictionary:
				_rows = v
	return _rows

## The model row for a slug ({} when unknown). Falls back to the slice's enemies.json rows.
static func model_entry(s: String) -> Dictionary:
	var r: Dictionary = rows()
	if r.has(s):
		return r[s]
	var e: Dictionary = DmData.enemies().get("models", {})
	return e.get(s, {})

static func lin(hex: int) -> Vector3:
	var c := Color(float((hex >> 16) & 255) / 255.0, float((hex >> 8) & 255) / 255.0, float(hex & 255) / 255.0).srgb_to_linear()
	return Vector3(c.r, c.g, c.b)

func _init(model_slug: String, o: Dictionary = {}) -> void:
	slug = model_slug
	rig_slug = model_slug
	opts = o
	_shadow_on = bool(o.get("cast_shadow", true))
	_spectral = bool(o.get("spectral", false))
	_gear = bool(o.get("gear_tint", false))
	_fade_loco = float(o.get("locomotion_fade", FADE_LOCOMOTION))
	for i in 4:
		_gear_tint.append(Vector4(1, 1, 1, 0))
		_gear_glow.append(Vector3.ZERO)
	root = Node3D.new()
	root.name = "Creature_" + model_slug
	entry = model_entry(model_slug)
	var scale_opt := float(o.get("scale", 1.0))
	var use := entry
	if entry.is_empty() or not ResourceLoader.exists(DmModels.BASE + String(entry.url)):
		var fb: String = String(o.get("fallback", ""))
		var fe := model_entry(fb) if fb != "" else {}
		if fb != "" and not fe.is_empty() and ResourceLoader.exists(DmModels.BASE + String(fe.url)):
			use = fe
			rig_slug = fb
			_wings = false
		else:
			push_warning("DmCreature: model missing for %s" % model_slug)
			return
	entry = use
	base_height = float(use.height) * scale_opt
	_wings = o.has("wings") and rig_slug == model_slug
	var c := DmModels.creature(String(use.url), base_height, float(use.yaw))
	var holder: Node3D = c.root
	_model = holder
	root.add_child(holder)
	ap = c.anim
	for sk in holder.find_children("*", "Skeleton3D", true, false):
		skeleton = sk
	_build_materials()
	if ap != null:
		_prep_clips()
		ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	loaded = true
	_start_loop(false)

# ----------------------------------------------------------------------------------------------------------------- materials

func _build_materials() -> void:
	var o := opts
	var tint_hex: Variant = o.get("tint")
	_params["tint"] = lin(int(tint_hex)) if tint_hex != null else Vector3.ONE
	var em_col := Vector3.ZERO
	var k := 0.0
	if o.has("emissive"):
		em_col = lin(int(o.emissive))
		k = float(o.get("emissive_intensity", 0.3))
	if _spectral:
		em_col = lin(int(o.get("emissive", 0x8f9ed1)))
		k = float(o.get("emissive_intensity", 0.9))
	_em_base = em_col
	_em_k = k
	_params["emis"] = em_col
	_params["emis_k"] = k
	if o.has("rim"):
		var rm: Dictionary = o.rim
		var rc := lin(int(rm.color))
		_params["rim"] = Color(rc.x, rc.y, rc.z, float(rm.strength))
	_use_fade = _spectral
	_cull_back = not _spectral and not _wings and DmCreatureMat.CULL_BACK_SLUGS.has(rig_slug)
	_params["opacity"] = 0.55 if _spectral else 1.0
	var wing_axis := 0.0
	var wing_vec := Vector4.ZERO
	var wing_root := Vector2.ZERO
	var phase := randf() * TAU
	for mi in _model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		if _gear:
			m.mesh = DmCreatureMat.baked_mesh(m)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if (_shadow_on and not _spectral) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _wings:
			var bb := m.mesh.get_aabb()
			var wo: Dictionary = o.wings
			var axis_z := bb.size.z > bb.size.x
			wing_axis = 1.0 if axis_z else 0.0
			var half := (bb.size.z if axis_z else bb.size.x) / 2.0
			var center := (bb.position.z + bb.size.z / 2.0) if axis_z else (bb.position.x + bb.size.x / 2.0)
			wing_vec = Vector4(float(wo.speed), float(wo.amp), half * float(wo.get("body", 0.3)), half)
			wing_root = Vector2(center, phase)
		for s in m.mesh.get_surface_count():
			var src: Material = m.mesh.surface_get_material(s)
			var op := DmCreatureMat.make(src, _spectral, _wings, _gear, _cull_back)
			var rec := {"mi": m, "surf": s, "op": op, "fade": null, "src": src}
			if _wings:
				op.set_shader_parameter("wing", wing_vec)
				op.set_shader_parameter("wing_root", wing_root)
				op.set_shader_parameter("wing_z", wing_axis)
			_meshes.append(rec)
			for key in _params:
				op.set_shader_parameter(key, _params[key])
			m.set_surface_override_material(s, op)

func _fade_for(rec: Dictionary) -> ShaderMaterial:
	if rec.fade == null:
		var fm := DmCreatureMat.make(rec.src, true, _wings, _gear, _cull_back)
		var op: ShaderMaterial = rec.op
		for key in _params:
			fm.set_shader_parameter(key, _params[key])
		if _wings:
			for key in ["wing", "wing_root", "wing_z"]:
				fm.set_shader_parameter(key, op.get_shader_parameter(key))
		if _gear:
			_copy_gear(fm)
		rec.fade = fm
	return rec.fade

func _p(name: String, v: Variant) -> void:
	_params[name] = v
	for rec in _meshes:
		(rec.op as ShaderMaterial).set_shader_parameter(name, v)
		if rec.fade != null:
			(rec.fade as ShaderMaterial).set_shader_parameter(name, v)

func _show_variant() -> void:
	for rec in _meshes:
		var m: MeshInstance3D = rec.mi
		m.set_surface_override_material(rec.surf, _fade_for(rec) if _use_fade else rec.op)

func _copy_gear(m: ShaderMaterial) -> void:
	for i in 4:
		var t: Vector4 = _gear_tint[i]
		m.set_shader_parameter("gt%d" % i, Color(t.x, t.y, t.z, t.w))
		m.set_shader_parameter("gg%d" % i, _gear_glow[i])
	m.set_shader_parameter("head_t", Color(_head_tint.x, _head_tint.y, _head_tint.z, _head_tint.w))
	m.set_shader_parameter("head_g", _head_glow)

func _push_gear() -> void:
	for rec in _meshes:
		_copy_gear(rec.op)
		if rec.fade != null:
			_copy_gear(rec.fade)

## Hit flash (Creature `flash` setter): pulses the emissive toward the pale flash colour, in FLASH_LEVELS steps.
func set_flash(v: float) -> void:
	if absf(v - _flash_v) < 0.02:
		return
	_flash_v = v
	var level := roundi(clampf(v, 0.0, 1.0) * FLASH_LEVELS)
	if level == _flash_level:
		return
	_flash_level = level
	_apply_flash(float(level) / FLASH_LEVELS)

func _apply_flash(f: float) -> void:
	if f > 0.01:
		var fc := lin(FLASH_COLOR)
		_p("emis", _em_base.lerp(fc, minf(1.0, f)))
		_p("emis_k", _em_k + f * 0.16)
	else:
		_p("emis", _em_base)
		_p("emis_k", _em_k)

func set_emissive(hex: int, intensity: float) -> void:
	_em_base = lin(hex)
	_em_k = intensity
	_apply_flash(float(_flash_level) / FLASH_LEVELS)

func set_cast_shadow(on: bool) -> void:
	if _shadow_on == on:
		return
	_shadow_on = on
	for rec in _meshes:
		(rec.mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if (on and not _spectral) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func set_opacity(o: float) -> void:
	_opacity = o
	var want_fade := o < 1.0 or _spectral
	_p("opacity", (0.55 if _spectral else 1.0) * o)
	if want_fade != _use_fade:
		_use_fade = want_fade
		_show_variant()

func opacity() -> float:
	return _opacity

## Recolour one body region (chest/legs/hands/feet; null clears it). Needs the `gear_tint` option.
func set_region_tint(region: String, tint: Variant) -> void:
	var i := GEAR_REGIONS.find(region)
	if i < 0:
		return
	if tint == null:
		_gear_tint[i] = Vector4(1, 1, 1, 0)
		_gear_glow[i] = Vector3.ZERO
	else:
		var c := lin(int(tint.color))
		_gear_tint[i] = Vector4(c.x, c.y, c.z, float(tint.get("strength", 0.7)))
		_gear_glow[i] = lin(int(tint.glow)) * 0.6 if tint.get("glow") else Vector3.ZERO
	_push_gear()

func set_head_tint(tint: Variant) -> void:
	if tint == null:
		_head_tint = Vector4(1, 1, 1, 0)
		_head_glow = Vector3.ZERO
	else:
		var c := lin(int(tint.color))
		_head_tint = Vector4(c.x, c.y, c.z, float(tint.get("strength", 0.55)))
		_head_glow = lin(int(tint.glow)) * 0.6 if tint.get("glow") else Vector3.ZERO
	_push_gear()

# ----------------------------------------------------------------------------------------------------------------- clips

func _track_of(a: Animation, bone: String, type: int) -> int:
	for i in a.get_track_count():
		if a.track_get_type(i) == type and String(a.track_get_path(i)).get_slice(":", 1) == bone:
			return i
	return -1

## stripRootTravel / inPlaceHeroClip: the sim owns the body's ground position, so the Hip's ground-plane travel is pinned (enemies) or
## dropped (heroes), keeping only the vertical bob. Applied once per shared Animation resource.
func _prep_clips() -> void:
	var hero := bool(opts.get("in_place", false))
	var idle: Animation = ap.get_animation("idle") if ap.has_animation("idle") else null
	var anchor: Variant = null
	if idle != null:
		var it := _track_of(idle, "Hip", Animation.TYPE_POSITION_3D)
		if it >= 0 and idle.track_get_key_count(it) > 0:
			anchor = idle.track_get_key_value(it, 0)
	for nm in ap.get_animation_list():
		var a := ap.get_animation(nm)
		if a.has_meta("dm_prep") and a.get_meta("dm_prep") == (2 if hero else 1):
			continue
		var base := String(nm).rstrip("0123456789")
		if hero:
			if base == "death":
				a.set_meta("dm_prep", 2)
				continue
			if COMBAT.has(String(nm)) and anchor != null:
				var t := _track_of(a, "Hip", Animation.TYPE_POSITION_3D)
				if t >= 0:
					for k in a.track_get_key_count(t):
						var v: Vector3 = a.track_get_key_value(t, k)
						a.track_set_key_value(t, k, Vector3(anchor.x, anchor.y, anchor.z + v.z))
				_drop_root(a)
			else:
				_drop_root(a)
				var ht := _track_of(a, "Hip", Animation.TYPE_POSITION_3D)
				if ht >= 0:
					a.remove_track(ht)
				if nm == "cast" or nm == "dig":
					var secs := minf(a.length, 1.3 if nm == "dig" else 1.1)
					_trim(a, ceilf(secs * 30.0) / 30.0)
		else:
			if not (base in ["death", "dive", "dig"]):
				var ht2 := _track_of(a, "Hip", Animation.TYPE_POSITION_3D)
				if ht2 >= 0 and a.track_get_key_count(ht2) > 0:
					var first: Vector3 = a.track_get_key_value(ht2, 0)
					var ax: float = anchor.x if anchor != null else first.x
					var ay: float = anchor.y if anchor != null else first.y
					for k in a.track_get_key_count(ht2):
						var v2: Vector3 = a.track_get_key_value(ht2, k)
						a.track_set_key_value(ht2, k, Vector3(ax, ay, v2.z))
		a.set_meta("dm_prep", 2 if hero else 1)

func _drop_root(a: Animation) -> void:
	for i in range(a.get_track_count() - 1, -1, -1):
		var p := String(a.track_get_path(i))
		if p.get_slice(":", 1) == "Root":
			a.remove_track(i)

func _trim(a: Animation, to: float) -> void:
	for i in a.get_track_count():
		for k in range(a.track_get_key_count(i) - 1, -1, -1):
			if a.track_get_key_time(i, k) > to + 1e-6:
				a.track_remove_key(i, k)
	a.length = to

func has(anim: String) -> bool:
	return ap != null and ap.has_animation(anim)

func clip_duration(anim: String) -> float:
	return ap.get_animation(anim).length if has(anim) else 0.0

func _resolve(anim: String) -> String:
	if ap == null or not FALLBACK.has(anim):
		return ""
	for nm in FALLBACK[anim]:
		if not ap.has_animation(nm):
			continue
		if anim == nm and (anim == "attack" or anim == "hurt" or anim == "death"):
			var pool: Array = [nm]
			for i in range(2, 4):
				if ap.has_animation("%s%d" % [nm, i]):
					pool.append("%s%d" % [nm, i])
			return pool[randi() % pool.size()]
		return nm
	return ""

func _stand_in(clip: String) -> bool:
	return _loop == "idle" and clip != "" and clip != "idle"

func _is_stride(n: String) -> bool:
	return n == "walk" or n == "run"

func _start_loop(fade: bool, fade_s: float = -1.0) -> void:
	if ap == null:
		return
	if fade_s < 0.0:
		fade_s = _fade_loco
	var nxt := _resolve(_loop)
	if nxt == "":
		return
	var sp := IDLE_STAND_IN if _stand_in(nxt) else _loop_speed
	if nxt == _current and _one_shot == "" and ap.is_playing():
		ap.speed_scale = sp
		return
	var phase := -1.0
	if fade and _current != "" and _current != nxt and _is_stride(_current) and _is_stride(nxt) and ap.has_animation(_current):
		var la := ap.get_animation(_current).length
		if la > 0.0:
			phase = ap.current_animation_position / la
	ap.speed_scale = sp
	ap.play(nxt, fade_s if (fade and _current != "") else 0.0, 1.0)
	if phase >= 0.0:
		ap.seek(phase * ap.get_animation(nxt).length, true)
	_current = nxt

## Base looping state (idle / walk / run). `speed` scales playback.
func set_loop(anim: String, speed: float = 1.0) -> void:
	_loop_speed = speed
	if _current != "" and _loop == anim:
		if _one_shot == "":
			ap.speed_scale = IDLE_STAND_IN if _stand_in(_current) else speed
		return
	_loop = anim
	if _one_shot == "":
		_start_loop(true)

## True while a one-shot (swing, cast, death) is playing: the view layer never throttles those.
func busy() -> bool:
	return _one_shot != ""

func one_shot_name() -> String:
	return _one_shot

## Phase (0..1) of the walk / run loop, or -1 while another clip plays (footsteps read it).
func loop_phase() -> float:
	if ap == null or _one_shot != "" or (_loop != "walk" and _loop != "run") or not ap.is_playing():
		return -1.0
	var d := ap.current_animation_length
	if d <= 0.0:
		return -1.0
	var ph := fmod(ap.current_animation_position, d) / d
	return ph + 1.0 if ph < 0.0 else ph

func world_height() -> float:
	return base_height * root.scale.x

## Walk or run at the pace that matches `ground` (units/s of real movement), with this model's measured stride.
func set_ground_speed(ground: float) -> Dictionary:
	# (cheapest tests first: this is asked for every walking body every frame and almost always answers "same plan")
	if _one_shot == "" and absf(ground - _last_ground) < 0.01 * maxf(1.0, ground) and not last_plan.is_empty() and _loop == String(last_plan.clip):
		return last_plan
	_last_ground = ground
	var stride: Dictionary = entry.get("stride") if entry.get("stride") is Dictionary else {}
	var plan := DmAnimator.plan_loco(stride, world_height(), ground, has("run"), _loco_run)
	_loco_run = plan.clip == "run"
	last_plan = plan
	set_loop(plan.clip, plan.timeScale)
	return plan

## A timed strike: the clip's measured impact frame lands `impact_in` seconds from now (strikeTiming).
func play_strike(anim: String, impact_in: float, follow_through: float = 0.3) -> bool:
	if not play_once(anim):
		return false
	var nm := _one_shot
	if nm == "" or nm.begins_with("death"):
		return true
	var dur := ap.get_animation(nm).length
	var timings: Dictionary = entry.get("timings", {})
	var timing: Variant = timings.get(nm)
	var impact := float(timing[1]) if timing is Array and timing.size() > 1 else -1.0
	var t := DmAnimator.strike_timing(dur, impact, impact_in, follow_through)
	ap.speed_scale = t.speed
	ap.seek(t.startAt, true)
	_one_shot_end = t.endAt
	return true

## One-shot overlay (attack / cast / hurt / death / dig ...); returns to the loop after.
func play_once(anim: String, speed: float = 1.0, duration_s: float = 0.0, start_at: float = 0.0) -> bool:
	if ap == null:
		return false
	if anim == "hurt" and has("hurt"):
		return flinch()
	var nm := _resolve(anim)
	if nm == "":
		return false
	if _one_shot != "" and anim == "hurt":
		return true
	if _death_clip != "":
		return true
	var a := ap.get_animation(nm)
	a.loop_mode = Animation.LOOP_NONE
	var sp := a.length / maxf(0.12, duration_s) if duration_s > 0.0 else speed
	ap.speed_scale = sp
	ap.play(nm, 0.08 if _current != "" else 0.0, 1.0)
	ap.seek(minf(start_at, a.length) if start_at > 0.0 else 0.0, true)
	_one_shot = nm
	_current = nm
	_one_shot_end = -1.0
	_flinch_t = -1.0
	return true

## Death clip held on its last frame. Returns false for rigs with no death clip (the owner tips the body over instead).
func play_death() -> bool:
	if ap == null:
		return false
	var nm := _resolve("death")
	if nm == "":
		return false
	var a := ap.get_animation(nm)
	a.loop_mode = Animation.LOOP_NONE
	ap.speed_scale = 1.0
	ap.play(nm, 0.05 if _current != "" else 0.0, 1.0)
	_one_shot = nm
	_current = nm
	_one_shot_end = -1.0
	_death_clip = nm
	return true

## A short hit-react (the first half-second of the hurt clip), never over a swing, cast or death. Returns false when the rig has no hurt clip.
func flinch(_strength: float = 0.85) -> bool:
	if ap == null or not has("hurt"):
		return false
	if _one_shot != "":
		return true
	var nm := _resolve("hurt")
	var a := ap.get_animation(nm)
	a.loop_mode = Animation.LOOP_NONE
	ap.speed_scale = FLINCH_SPEED
	ap.play(nm, 0.06 if _current != "" else 0.0, 1.0)
	_one_shot = nm
	_current = nm
	_one_shot_end = minf(a.length, FLINCH_SECONDS * FLINCH_SPEED)
	return true

## Let locomotion blend out a hero gesture as soon as walking resumes.
func release_gesture() -> void:
	if not bool(opts.get("in_place", false)) or _one_shot == "" or _one_shot.rstrip("0123456789") in ["death", "hurt"]:
		return
	_one_shot = ""
	_one_shot_end = -1.0
	_start_loop(true, FADE_RETURN)

## Jump a clip to its last frame (corpses of late joiners).
func hold_last_frame(anim: String) -> bool:
	var nm := _resolve(anim)
	if nm == "":
		return false
	var a := ap.get_animation(nm)
	a.loop_mode = Animation.LOOP_NONE
	ap.speed_scale = 1.0
	ap.play(nm, 0.0, 1.0)
	ap.seek(a.length, true)
	_one_shot = nm
	_current = nm
	if nm.begins_with("death"):
		_death_clip = nm
	return true

## Seconds into a death clip at which the body has come to rest (inPlaceAnimation.landingTime): the first moment the Hip's
## height (local Z) is within 10% of its lowest point; 70% of the clip when there is no Hip track.
func landing_time(nm: String) -> float:
	var a := ap.get_animation(nm)
	if _landings.has(a):
		return _landings[a]
	var t := a.length * 0.7
	var tr := _track_of(a, "Hip", Animation.TYPE_POSITION_3D)
	if tr >= 0 and a.track_get_key_count(tr) > 2:
		var lo := INF
		var hi := -INF
		for k in a.track_get_key_count(tr):
			var z: float = (a.track_get_key_value(tr, k) as Vector3).z
			lo = minf(lo, z)
			hi = maxf(hi, z)
		if hi - lo > 1e-4:
			for k in a.track_get_key_count(tr):
				if (a.track_get_key_value(tr, k) as Vector3).z <= lo + 0.1 * (hi - lo):
					t = a.track_get_key_time(tr, k)
					break
	_landings[a] = t
	return t

## True once a dying body has come to rest (its death clip's landing moment, or the tip-over for models without one).
func has_landed() -> bool:
	if toppled > 0.0:
		return toppled >= 0.8
	if _death_clip == "" or ap == null:
		return false
	if not ap.is_playing():
		return true
	return ap.current_animation_position >= landing_time(_death_clip)

## Animation LOD: seconds between `update` calls for a body at `p`, measured on the ground from the point the camera looks at (the followed
## hero / screen centre), not from the camera itself (which sits ~22 m up and back, so everything on screen used to count as mid-distance).
## Everything the screen can show (about 1.6 x the camera height, 29 m at the default zoom, 41 m at max) updates every frame (0), the band
## just outside ~30 Hz, the rest ~10 Hz.
static func lod_interval(cam: Camera3D, p: Vector3) -> float:
	var f := -cam.global_transform.basis.z
	var h := cam.global_position.y
	if f.y > -0.05 or h <= 0.0:
		return 0.0
	var t := h / -f.y
	var full := maxf(28.0, h * 1.6)
	var d := Vector2(p.x - (cam.global_position.x + f.x * t), p.z - (cam.global_position.z + f.z * t)).length()
	return 0.0 if d < full else (0.033 if d < full * 1.6 else 0.1)

## Advance by a real frame (the picture clock of a struck enemy honours the hitstop).
func update(dt_real: float) -> void:
	if ap == null or _disposed:
		return
	var dt := dt_real * (hitstop_scale if bool(opts.get("hitstop", false)) else 1.0)
	ap.advance(dt)
	if _one_shot != "" and _death_clip == "":
		if _one_shot_end >= 0.0 and ap.current_animation_position >= _one_shot_end:
			_one_shot = ""
			_one_shot_end = -1.0
			_start_loop(true, FADE_RETURN)
		elif not ap.is_playing():
			_one_shot = ""
			_one_shot_end = -1.0
			_current = ""
			_start_loop(false)
	if not _pending.is_empty() and root.is_inside_tree():
		_flush_pending()
	var settled := _one_shot == "" and (_current == "idle" or not has("idle"))
	_settled_t = _settled_t + dt if settled else 0.0
	if not _attached.is_empty():
		_tick_props(dt)

# ----------------------------------------------------------------------------------------------------------------- props

func after_load(cb: Callable) -> void:
	if loaded:
		cb.call()
	else:
		_after_load.append(cb)

## Parent `obj` to a bone. With `dir` (character-local, e.g. straight up) the prop's +Y is aimed along it once the idle pose settles
## (calibration), and `follow` (0..1) keeps it from whipping around with the wrist (1 = hand-driven). `fit`: {roll, offset: Vector3}.
func attach(bone: String, obj: Node3D, dir: Variant = null, follow: Variant = null, fit: Dictionary = {}) -> void:
	_pending.append([bone, obj, dir, follow, fit])
	if root.is_inside_tree():
		_flush_pending()

func _flush_pending() -> void:
	if skeleton == null:
		return
	var list := _pending
	_pending = []
	for p in list:
		var bone: String = p[0]
		var obj: Node3D = p[1]
		if obj == null or not is_instance_valid(obj):
			continue
		var att := BoneAttachment3D.new()
		att.name = "Prop_" + bone
		att.bone_name = bone if skeleton.find_bone(bone) >= 0 else "Hip"
		skeleton.add_child(att)
		att.add_child(obj)
		# Attachments are authored in world units: cancel the bone chain's scale.
		var gs := att.global_transform.basis.get_scale().x
		var rs := root.global_transform.basis.get_scale().x
		obj.scale = obj.scale * (rs / maxf(gs, 1e-6))
		if p[2] != null:
			var d := (p[2] as Vector3).normalized()
			_attached.append({"obj": obj, "att": att, "dir": d, "follow": p[3], "base_q": null, "fit": p[4], "cal": 4})

func detach(obj: Node3D) -> void:
	_pending = _pending.filter(func(p): return p[1] != obj)
	for i in range(_attached.size() - 1, -1, -1):
		if _attached[i].obj == obj:
			_attached.remove_at(i)
	var par := obj.get_parent()
	if par != null:
		par.remove_child(obj)
		if par is BoneAttachment3D:
			par.queue_free()

func _root_rotation() -> Quaternion:
	return root.global_transform.basis.orthonormalized().get_rotation_quaternion()

func _tick_props(dt: float) -> void:
	var any_cal := false
	for a in _attached:
		if a.cal > 0:
			any_cal = true
	if any_cal:
		if _settled_t > 0.25:
			var root_q := _root_rotation()
			for a in _attached:
				if a.cal <= 0:
					continue
				a.cal -= 1
				if a.cal > 0:
					continue
				_calibrate(a, root_q)
		return
	var every := maxi(3, steady_every) if (_settled_t > 0.6 and _one_shot == "") else steady_every
	_steady_n += 1
	if every > 1 and _steady_n < every:
		return
	_steady_n = 0
	var root_q := _root_rotation()   # (only past the throttle above: it used to be computed, and discarded, every frame)
	for a in _attached:
		if a.base_q == null:
			continue
		var att: BoneAttachment3D = a.att
		var pq := att.global_transform.basis.orthonormalized().get_rotation_quaternion()
		var driven: Quaternion = pq * (a.base_q as Quaternion)
		var up := driven * Vector3.UP
		var want := root_q * (a.dir as Vector3)
		var locked := Quaternion(up.normalized(), want.normalized()) * driven
		driven = driven.slerp(locked, 1.0 - float(a.follow if a.follow != null else 1.0))
		(a.obj as Node3D).quaternion = pq.inverse() * driven
	if _settled_t > 0.6 and _one_shot == "":
		_recheck_t -= dt
		if _recheck_t <= 0.0:
			_recheck_t = 2.0
			for a in _attached:
				var oq := (a.obj as Node3D).global_transform.basis.orthonormalized().get_rotation_quaternion()
				var upv := oq * Vector3.UP
				if upv.angle_to(root_q * (a.dir as Vector3)) > deg_to_rad(25.0):
					a.cal = 1

func _calibrate(a: Dictionary, root_q: Quaternion) -> void:
	var att: BoneAttachment3D = a.att
	var obj: Node3D = a.obj
	var pq := att.global_transform.basis.orthonormalized().get_rotation_quaternion()
	var want: Vector3 = pq.inverse() * (root_q * (a.dir as Vector3))
	var q := Quaternion(Vector3.UP, want.normalized())
	var fit: Dictionary = a.fit
	if fit.get("roll", 0.0) != 0.0 and fit.get("roll") != null:
		q = q * Quaternion(Vector3.UP, float(fit.roll))
	obj.quaternion = q
	var off: Variant = fit.get("offset")
	if off != null:
		var s := att.global_transform.basis.get_scale().x
		obj.position = (pq.inverse() * (root_q * (off as Vector3))) / maxf(s, 1e-6)
	if a.follow != null:
		a.base_q = q

## Back to a freshly-built state so a pooled body can stand up as a new enemy (DmEntityViews reuses dead enemies' creatures
## instead of instancing the model again): pose, transform, flash, emissive, opacity, shadows and the clip state.
func recycle_reset() -> void:
	toppled = 0.0
	steady_every = 1
	last_plan = {}
	_last_ground = -1.0
	_settled_t = 0.0
	_recheck_t = 0.0
	_steady_n = 0
	root.position = Vector3.ZERO
	root.rotation = Vector3.ZERO
	root.scale = Vector3.ONE
	root.visible = true
	_flash_v = 0.0
	_flash_level = 0
	_build_emissive_base()
	_apply_flash(0.0)
	set_opacity(1.0)
	set_cast_shadow(bool(opts.get("cast_shadow", true)))
	_one_shot = ""
	_one_shot_end = -1.0
	_death_clip = ""
	_flinch_t = -1.0
	_loop = "idle"
	_loop_speed = 1.0
	_current = ""
	if ap != null:
		ap.stop()
		ap.speed_scale = 1.0
	_start_loop(false)


func _build_emissive_base() -> void:
	var em_col := Vector3.ZERO
	var k := 0.0
	if opts.has("emissive"):
		em_col = lin(int(opts.emissive))
		k = float(opts.get("emissive_intensity", 0.3))
	if _spectral:
		em_col = lin(int(opts.get("emissive", 0x8f9ed1)))
		k = float(opts.get("emissive_intensity", 0.9))
	_em_base = em_col
	_em_k = k


func dispose() -> void:
	_disposed = true
	if ap != null:
		ap.stop()
	if root != null and is_instance_valid(root):
		if root.is_inside_tree():
			root.get_parent().remove_child(root)
		root.free()
