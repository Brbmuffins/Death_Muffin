class_name DmFxRuntime
extends Node3D
## DmFx: the Godot port of Effects.ts + the BinbunVFX runtime + necroFx.ts. Register as an autoload named `DmFx`
## (project.godot: `DmFx="*res://fx/dm_fx.gd"`), or create one with DmFxRuntime.new() and add it to the world (tests, gallery).
## See res://fx/README.md for the API and the table mapping every web call site to a call here.
##
## Two layers, like the web: the procedural primitives of Effects.ts (emit / emit_smoke / decal / flash / orbit / beam /
## projectile / spike_ring / spike_line / grave_hands / bone_orbit / light_flash) and the Binbun scenes (play / stop).
## Settings the integrator keeps in sync with the web's settings: `quality`, `reduced_motion`, `hitstop_scale`.

## "high" | "low". Low has no Binbun layer and thins every burst to 75 % (Effects.ts LOW_PARTICLE_SCALE).
var quality := "high":
	set(v):
		quality = v
		if prims != null:
			prims.quality = v
		if binbun != null:
			binbun.enabled = v == "high"
var reduced_motion := false
## Hitstop scale (hitstop.scale in the web): 1 = normal, 0 = frozen.
var hitstop_scale := 1.0

var binbun: DmFxBinbun
var prims: DmFxPrims
var motifs: DmFxMotifs
var _flash_light: OmniLight3D
var _flash_t := 0.0
var _flash_life := 0.0
var _flash_peak := 0.0
var _lights_n: int = 1


func _init() -> void:
	name = "DmFx"
	binbun = DmFxBinbun.new(self)
	binbun.flash_cb = light_flash


func _ready() -> void:
	prims = DmFxPrims.new(self)
	prims.quality = quality
	motifs = DmFxMotifs.new(self, prims)
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color("a26bff")
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 9.0
	_flash_light.omni_attenuation = 1.6
	_flash_light.shadow_enabled = false
	_flash_light.visible = false   # a light at zero energy still costs every lit fragment loop; shown only while a flash plays
	add_child(_flash_light)
	binbun.enabled = quality == "high"


# --- Binbun ---------------------------------------------------------------------------------------------------------

## Play a Binbun effect (docs/BINBUN-VFX-PORT.md). `pos` is the world position; opts (all optional):
##   colors   Array of Color / 0xRRGGBB (primary, secondary, tertiary); default = the effect's FX_PRESETS colours
##   scale    multiplies the preset scale          alpha   multiplies the preset opacity
##   rot      yaw radians, or dir (Vector3 facing) y       overrides the preset height (else pos.y)
##   follow   Callable -> Vector3 | null (null ends the effect)   duration  seconds before it fades out (loopers)
##   once     one-off impact (default: true for the catalog's impacts)   raw  true = ignore the preset (gallery)
func play(effect_id: String, pos: Vector3, opts: Dictionary = {}) -> DmFxHandle:
	if quality != "high":
		return DmFxHandle.new()
	var o := opts.duplicate()
	var p := {} if bool(o.get("raw", false)) else DmFxData.preset(effect_id)
	var y := pos.y
	if o.has("y"):
		y = float(o["y"])
	elif p.has("y"):
		y = float(p["y"])
	if not o.has("colors") and p.has("colors"):
		o["colors"] = p["colors"]
	if not o.has("once"):
		o["once"] = DmFxData.is_impact(effect_id)
	o["scale"] = float(p.get("scale", 1.0)) * float(o.get("scale", 1.0))
	o["alpha"] = float(p.get("alpha", 1.0)) * float(o.get("alpha", 1.0))
	if o.has("dir") and o["dir"] is Vector3:
		var d: Vector3 = o["dir"]
		o["rot"] = atan2(d.x, d.z)
	if prims != null and prims.dims_binbun():
		o = prims.partner_binbun(o)
	return binbun.spawn(effect_id, Vector3(pos.x, y, pos.z), o)


## Colours of a SPELL_FX group as [Color, ...] in the order of its keys, e.g. spell_colors("miasma") -> [rot, deep, spore].
func spell_colors(group: String) -> Array:
	return DmFxData.spell_group(group).values()


func stop(handle: DmFxHandle) -> void:
	if handle != null:
		handle.kill()


## Number of Binbun effects playing (QA).
func binbun_count() -> int:
	return binbun.count()


# --- Effects.ts primitives (thin forwards, so call sites read like the web's `effects.x(...)`) ---------------------------

func emit(o: Dictionary) -> void:
	prims.emit(o)


func emit_smoke(o: Dictionary) -> void:
	prims.emit_smoke(o)


func decal(o: Dictionary) -> DmFxHandle:
	return prims.decal(o)


func flash(o: Dictionary) -> DmFxHandle:
	return prims.flash(o)


func orbit(o: Dictionary) -> DmFxHandle:
	return prims.orbit(o)


func beam(a: Variant, b: Callable, color: Variant, width: float, duration: float) -> DmFxHandle:
	return prims.beam(a, b, color, width, duration)


func projectile(o: Dictionary) -> DmFxPrims.ProjectileRef:
	return prims.projectile(o)


func spike_ring(x: float, z: float, r: float, count: int, life := 1.9) -> void:
	prims.spike_ring(x, z, r, count, life)


func spike_line(x: float, z: float, dir_x: float, dir_z: float, length: float, width: float, sequential := true) -> void:
	prims.spike_line(x, z, dir_x, dir_z, length, width, sequential)


func grave_hands(x: float, z: float, r: float, count: int, duration: float) -> DmFxHandle:
	return prims.grave_hands(x, z, r, count, duration)


func bone_orbit(o: Dictionary) -> DmFxHandle:
	return prims.bone_orbit(o)


## Everything decal()-ed inside `fn` is a danger telegraph (drawn above friendly ground effects, never faded).
func danger(fn: Callable, when := true) -> Variant:
	return prims.danger(fn, when)


func transient_load() -> int:
	return prims.transient_load()


func active_hand_fields() -> int:
	return prims.active_hand_fields()


## Share of each particle burst drawn (the scene lowers it while it plays another player's cast).
var particle_scale: float:
	get:
		return prims.particle_scale
	set(v):
		prims.particle_scale = v


## "self" | "other": whose ground effects are drawn (another player's: faint and outline-only). WorldScene sets it around a remote
## player's events.
var role: String:
	get:
		return prims.role
	set(v):
		prims.role = v


func partner_binbun(o: Dictionary) -> Dictionary:
	return prims.partner_binbun(o)


## Transient coloured light for big casts (one shared OmniLight3D, like Effects.lightFlash).
func light_flash(pos: Vector3, color: Color, intensity: float, life: float = 0.35) -> void:
	if _flash_light == null:
		return
	if _flash_life > 0.0 and _flash_light.light_energy > intensity * 1.25:
		return
	_flash_light.position = pos
	_flash_light.visible = true
	_flash_light.light_color = color
	_flash_t = 0.0
	_flash_life = life
	_flash_peak = intensity


# --- frame ----------------------------------------------------------------------------------------------------------

## Accumulated _process time in microseconds while `prof_on` (the F3 overlay turns it on): the fx share of a frame.
var prof_on := false
var prof_us := 0

func _process(dt_real: float) -> void:
	if prims == null:
		return
	var prof_t0 := Time.get_ticks_usec() if prof_on else 0
	_frame(dt_real)
	if prof_on:
		prof_us += Time.get_ticks_usec() - prof_t0


func _frame(dt_real: float) -> void:
	# Particles hang in the air during a hitstop.
	var dt := dt_real * hitstop_scale
	binbun.time_scale = hitstop_scale
	binbun.update(dt, get_viewport().get_camera_3d())
	prims.update(dt, dt_real)
	if _flash_life > 0.0:
		_flash_t += dt
		var k := _flash_t / _flash_life
		if k >= 1.0:
			_flash_life = 0.0
			_flash_light.light_energy = 0.0
			_flash_light.visible = false
		else:
			_flash_light.light_energy = _flash_peak * (1.0 - k) * (1.0 - k)


## Stop everything playing (area change / scene teardown keeps the pools).
func clear() -> void:
	binbun.clear()


## Stop and drop everything, persistent decals included: call before freeing the owner of any `follow` closures (DmNextGame._exit_tree).
func clear_all() -> void:
	binbun.clear()
	if prims != null:
		prims.clear()


func _exit_tree() -> void:
	if binbun != null:
		binbun.dispose()
	if prims != null:
		prims.dispose()
