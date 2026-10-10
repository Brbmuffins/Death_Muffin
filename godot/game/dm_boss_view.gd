class_name DmBossView
extends RefCounted
## Any boss's model (port of BossView in archive/legacy-web:src/graphics/Avatars.ts): one per boss id, created on first summon (the Prelate's is built at
## load). `sync(state: DmBossState, dt)` every frame, `hide()` after death / when the fight resets (fades out after 2.5 s), `dispose()`.
## Model and colour come from BOSSES[id].modelSlug / .color (godot/data/content/bosses.json).

var root: Node3D
var c: DmCreature
var boss_id := "prelate"
var slug := "prelate"
var color := 0xa26bff
var light: OmniLight3D
var vfx: Node = null
var _last_state := ""
var _visible := false
var _rise := 0.0
var _saint := false
var _regent := false
var _mire := false
var _sunk := 0.0
var _has_last := false
var _last_x := 0.0
var _last_z := 0.0
var _ground_speed := 0.0
var _fade_wait := -1.0
var _fade_t := 0.0
var _fading := false
var _light_k := 0.12   # three PointLight intensity (candela-ish) -> Godot omni energy


func setup(parent: Node, id: String = "prelate") -> void:
	boss_id = id
	var def: Dictionary = DmContent.boss(id)
	slug = String(def.get("modelSlug", "prelate"))
	color = int(def.get("color", 0xa26bff))
	root = Node3D.new()
	root.name = "BossView_" + id
	_saint = slug == "boss_plague_saint"
	_regent = slug == "boss_cinder_regent"
	_mire = slug == "boss_mire_mother"
	vfx = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Vfx")
	c = DmCreature.new(slug, {"emissive": 0x3b1d5e if slug == "prelate" else 0x000000, "emissive_intensity": 0.05 if slug == "prelate" else 0.0,
		"fallback": "prelate", "hitstop": true})
	c.root.visible = false
	root.add_child(c.root)
	if parent != null:
		parent.add_child(root)
	light = OmniLight3D.new()
	light.light_color = DmGearProps.col(color)
	light.light_energy = 0.0
	light.visible = false   # shown only while the boss glows (a zero-energy light still costs every lit fragment)
	light.omni_range = 14.0
	light.omni_attenuation = 1.4
	light.position = Vector3(0, 2.6, 0.6)
	c.root.add_child(light)

func _emit(o: Dictionary) -> void:
	if vfx != null:
		vfx.emit(o)

func _smoke(o: Dictionary) -> void:
	if vfx != null:
		vfx.emit_smoke(o)

func is_shown() -> bool:
	return _visible

func sync(b: DmBossState, dt: float) -> void:
	_tick_fade(dt)
	if vfx != null:
		DmCreature.hitstop_scale = float(vfx.hitstop_scale)
	if b.active and not _visible:
		_visible = true
		_rise = 0.0
		_fade_wait = -1.0
		_fading = false
		c.root.visible = true
		c.set_opacity(1.0)
		c.root.rotation.z = 0.0
	if not _visible:
		return
	_rise = minf(1.0, _rise + dt * 0.6)
	var now := float(Time.get_ticks_msec())
	if _mire:
		# She sinks into the marsh (hidden once under) and climbs back out with the same ease.
		_sunk += ((1.0 if (b.active and b.state == "sunk") else 0.0) - _sunk) * minf(1.0, dt * 4.0)
		c.root.visible = _sunk < 0.97
		if b.active and randf() < dt * (14.0 if _sunk > 0.3 else 4.0):
			_emit({"x": b.x + (randf() - 0.5) * 2.4, "y": 0.2 + (1.0 - _sunk) * randf() * 2.0, "z": b.z + (randf() - 0.5) * 2.4, "count": 1, "color": 0x5fc4b4 if randf() < 0.6 else 0x9fe8da, "spread": 0.3, "speed": 0.3, "up": 0.8, "life": 0.9, "size": 0.16, "drag": 0.5})
	c.root.position = Vector3(b.x, -4.6 * (1.0 - _rise) * (1.0 - _rise) - _sunk * 4.4, b.z)
	c.root.rotation.y = DmEntityViews.turn_toward(c.root.rotation.y, b.facing, dt, 3.0)
	var inst := 0.0 if not _has_last else DmEntityViews.step_speed(b.x - _last_x, b.z - _last_z, dt, 6.0)
	_has_last = true
	_last_x = b.x
	_last_z = b.z
	_ground_speed = DmEntityViews.smooth_speed(_ground_speed, inst, dt, 0.25)
	c.set_flash(b.flash if b.active else 0.0)
	# The Regent's pale cape and molten plate white out under a close 16-24 light: a warm, low glow instead.
	var glow := (4.0 + b.phase * 2.0) if (_regent or _mire) else (16.0 + b.phase * 8.0)
	# An Empowered boss (Covenant Seal summon) is bigger and burns red-gold: the tell that this fight pays more and hits harder.
	var emp := b.active and b.empowered
	light.light_color = DmGearProps.col(0xff6a2a if emp else color)
	var intensity := ((glow + sin(now / 200.0) * (1.0 if (_regent or _mire) else 4.0)) * (1.35 if emp else 1.0)) if b.active else maxf(0.0, light.light_energy / _light_k - dt * 30.0)
	light.light_energy = intensity * _light_k
	light.visible = light.light_energy > 0.001
	var grow := 1.12 if emp else 1.0
	c.root.scale = Vector3.ONE * grow
	if b.state != _last_state:
		_last_state = b.state
		match b.state:
			"toll", "rain", "summon":
				c.play_once("cast", 1.1)
			"slam":
				c.play_once("attack", 1.3)
			"move":
				c.set_ground_speed(_ground_speed if _ground_speed != 0.0 else 2.0)
			"dead":
				c.play_once("death", 0.8)
			_:
				c.set_loop("idle")
	elif b.state == "move":
		c.set_ground_speed(_ground_speed)
	if _saint and b.active:
		# Her clip set is small (idle/walk/attack/cast), so the blight itself is the tell: she swells and sheds more rot each phase.
		var ph: float = b.phase
		c.root.scale = Vector3.ONE * (grow * (1.0 + sin(now / 1000.0 * (1.6 + ph * 0.9)) * 0.012 * ph))
		if randf() < dt * (2.0 + ph * 3.0):
			_smoke({"x": b.x + (randf() - 0.5) * 2.0, "y": 0.3, "z": b.z + (randf() - 0.5) * 2.0, "count": 1, "color": 0x4a5a22, "spread": 0.8, "speed": 0.3, "up": 0.5, "life": 1.4, "size": 1.2})
	if _regent and b.active:
		# The Regent burns hotter each phase: embers stream off the crown and pauldrons, soot rolls off the cape.
		var ph2: float = b.phase
		c.root.scale = Vector3.ONE * (grow * (1.0 + sin(now / 1000.0 * (1.4 + ph2 * 0.8)) * 0.01 * ph2))
		if randf() < dt * (10.0 + ph2 * 10.0):
			_emit({"x": b.x + (randf() - 0.5) * 1.6, "y": 2.0 + randf() * 2.4, "z": b.z + (randf() - 0.5) * 1.6, "count": 1, "color": 0xff7a2a if randf() < 0.5 else 0xffc45a, "spread": 0.5, "speed": 0.4, "up": 1.2 + ph2 * 0.3, "life": 1.1, "size": 0.14, "drag": 0.4})
		if randf() < dt * (2.0 + ph2 * 2.0):
			_smoke({"x": b.x + (randf() - 0.5) * 2.0, "y": 1.2, "z": b.z + (randf() - 0.5) * 2.0, "count": 1, "color": 0x2a1408, "spread": 0.7, "speed": 0.3, "up": 0.7, "life": 1.6, "size": 1.3, "shrink": -0.5})
	if emp and randf() < dt * 14.0:
		_emit({"x": b.x + (randf() - 0.5) * 2.2, "y": 0.4 + randf() * 3.2, "z": b.z + (randf() - 0.5) * 2.2, "count": 1, "color": 0xff7a2a if randf() < 0.5 else 0xffc45a, "spread": 0.4, "speed": 0.4, "up": 1.4, "life": 1.1, "size": 0.16, "drag": 0.4})
	if b.active and randf() < dt * ((8.0 + b.phase * 8.0) if _saint else 10.0):
		_emit({"x": b.x, "y": 2.5, "z": b.z, "count": 1, "color": 0x9d6bff if color == 0xa26bff else color, "spread": 1, "speed": 0.4, "up": 0.8, "life": 1.2, "size": 0.4})
	c.update(dt)

## Fade out after death (or when the fight resets): waits 2.5 s, then fades over 1 s in 50 ms steps, like the web's timer.
func hide() -> void:
	if not _visible or _fade_wait >= 0.0 or _fading:
		return
	c.set_flash(0.0)
	_fade_t = 0.0
	_fade_wait = 2.5

## Advances the delayed fade (called from sync every frame; call it yourself if you stop syncing an inactive view).
func _tick_fade(dt: float) -> void:
	if _fade_wait >= 0.0:
		_fade_wait -= dt
		if _fade_wait < 0.0:
			_fading = true
		return
	if _fading:
		_fade_t += dt
		c.set_opacity(maxf(0.0, 1.0 - _fade_t))
		if _fade_t >= 1.0:
			c.root.visible = false
			_visible = false
			_fading = false

func tick(dt: float) -> void:
	_tick_fade(dt)

func dispose() -> void:
	if c != null:
		c.dispose()
	if root != null and is_instance_valid(root):
		if root.is_inside_tree():
			root.get_parent().remove_child(root)
		root.free()
