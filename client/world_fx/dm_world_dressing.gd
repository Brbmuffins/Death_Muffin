class_name DmWorldDressing
extends Node3D
## Everything the web draws around the static world that the world track left out, as one self-contained node:
##   stained-glass windows + light shafts, candle-flame sprites + brazier fire, far silhouettes (spires/trees/ruins), ground mist, per-area weather
##   (Atmosphere), standing water with ripples + moon glint. (Occlusion, wing flap, hover and wade ripples live in godot/world + godot/game.)
## Ported from godot/world_fx/dm_world_dressing.gd (client/code.list "Ported"): the world is `DmNextWorld`, whose area scenes carry no stand-ins for what this draws (the converter
## leaves out the flame spheres, the water planes and the puddle quads), so nothing is hidden at run time; the bloom is the graphics preset's (DmGraphicsPreset.apply_environment);
## the area the focus stands in comes from `set_area` (the world's `enter_area`) where today's asked the builder every frame; and what moves is moved the cheap way:
## flames, windows, silhouettes and water are static meshes or shaders, the weather and the brazier fire are drawn by their vertex shaders from a clock, the mist steps at 4 Hz and the
## brazier fire rolls its emission at 20 Hz. A frame costs this node a clock, three uniforms for the weather, one for the water and one for the brazier fire while it burns.
## Usage:
##     var dressing := DmWorldDressing.attach(world, focus)      # `world` = the DmNextWorld whose lights builder holds `world` data, `area_nodes` and `env`; `focus` follows the hero
## Per-area pieces (flames, windows) are children of the area scenes, so they leave with their area; global pieces (silhouettes, mist, weather, water, brazier fire) live under this
## node. Only the loaded areas get theirs. Per-feature switches (all default on) exist so the perf harness can measure each piece: see `features`.

const FEATURES := ["windows", "flames", "silhouettes", "mist", "atmosphere", "water"]
const FIRE_STEP := 0.05          ## seconds between the brazier fire's emission rolls (DmWfxBrazierFire.STEP)

var world: Node3D                ## the DmNextWorld: `builder` (the lights: world data, area_nodes) and `area_at`
var focus_node: Node3D
var data: Dictionary
var enabled := true
var features := {"windows": true, "flames": true, "silhouettes": true, "mist": true, "atmosphere": true, "water": true}
var quality := "high"   # high | low (low: flat water, half the weather)
var reduced_motion := false
var wade := false   # game-core's DmEventFx already rings the water (wadeRipples): it should call dressing.add_ripple/is_wet

var area_flames: Dictionary = {}     # area id -> MultiMeshInstance3D
var window_nodes: Array = []         # MeshInstance3D (pane, shaft pairs)
var silhouette_node: MeshInstance3D
var brazier_fire: DmWfxBrazierFire
var mist: DmWfxMist
var mist_node: Node3D
var atmosphere: DmWfxAtmosphere
var water: DmWfxWater
var candle_off: Dictionary = {}
var area := ""                       ## the area the focus stands in (`set_area`): the weather and the water's palette follow it
var clock := 0.0                     ## seconds this node has run: the shaders' time
var _fire_acc := 0.0
var _ripple_t := 0.0
var _ripple_cursor := 0
var _prev_pos: Dictionary = {}       # instance id -> Vector3 (movement detection for wading)

static func attach(w: Node3D, follow: Node3D = null) -> DmWorldDressing:
	var d := DmWorldDressing.new()
	d.name = "WorldDressing"
	d.world = w
	d.focus_node = follow
	w.add_child(d)
	d.build()
	return d

func build() -> void:
	data = DmWfxData.get_data()
	if data.is_empty():
		push_error("world_fx: godot/data/world_fx/fx.json missing (it is committed; restore it from git)")
		return
	var lights: DmWorldBuilder = world.builder
	var world_data: Dictionary = lights.world
	var order: Array = world_data.order
	var areas: Dictionary = lights.area_nodes
	# windows: under the nearest area's scene
	for w in data.windows:
		var id := DmWfxData.nearest_area(world_data.areas, order, float(w.x), float(w.z))
		if areas.has(id):
			window_nodes.append_array(DmWfxWindows.build(areas[id], w))
	# flames: one MultiMesh in each loaded area that has candles
	for id in data.flames:
		if not areas.has(id):
			continue
		var m := DmWfxFlames.build(areas[id], str(id), data.flames[id], candle_off)
		if m != null:
			m.set_meta("dressing", true)
			area_flames[id] = m
	for n in window_nodes:
		n.set_meta("dressing", true)
	# brazier fire near the focus (WorldView.update)
	brazier_fire = DmWfxBrazierFire.new()
	add_child(brazier_fire)
	brazier_fire.setup(world_data)
	brazier_fire.candle_off = candle_off
	# silhouettes
	silhouette_node = DmWfxSilhouettes.attach(self, data.silhouettes)
	# mist
	mist = DmWfxMist.new()
	add_child(mist)
	mist.setup(data.mist)
	mist_node = mist
	# weather
	atmosphere = DmWfxAtmosphere.new()
	add_child(atmosphere)
	atmosphere.setup(data)
	atmosphere.quality_low = quality == "low"
	# water
	water = DmWfxWater.new()
	add_child(water)
	water.setup(data.water.rects, data.water.puddles)
	_apply_features()
	set_area(world.area_id if world.area_id != "" else str(order[0]))
	for id in areas:   # every loaded area's weather is built while the world loads, so no area entry pays for it
		if data.atmosphere.profiles.has(id):
			atmosphere.warm(str(id))

## Master switch (perf A/B): everything off = the world as the area scenes draw it.
func set_enabled(on: bool) -> void:
	enabled = on
	_apply_features()

func set_feature(f: String, on: bool) -> void:
	features[f] = on
	_apply_features()

func _on(f: String) -> bool:
	return enabled and bool(features.get(f, true))

func _apply_features() -> void:
	for n in window_nodes:
		n.visible = _on("windows")
	for id in area_flames:
		area_flames[id].visible = _on("flames")
	if brazier_fire != null:
		brazier_fire.visible = _on("flames")
	if silhouette_node != null:
		silhouette_node.visible = _on("silhouettes")
	if mist_node != null:
		mist_node.visible = _on("mist")
	if atmosphere != null:
		atmosphere.visible = _on("atmosphere")
	if water != null:
		water.visible = _on("water")
	set_process(enabled and not data.is_empty())

## The focus has entered `id` (the world's `enter_area`): the weather cross-fades to it (the next tick) and the water takes its moon and palette.
func set_area(id: String) -> void:
	if id == "" or id == area:
		return
	area = id
	var amb: Dictionary = world.builder.world.areas[id].ambient
	water.set_moon(Color.html(str(amb.moon)))
	water.set_palette(id == "fen")

## Sanctum candle groups gutter out as the Prelate advances through phases (WorldView.setCandleGroup).
func set_candle_group(group: String, lit_on: bool) -> void:
	if lit_on:
		candle_off.erase(group)
	else:
		candle_off[group] = true
	for id in area_flames:
		DmWfxFlames.set_group_lit(area_flames[id], group, lit_on)

func is_wet(x: float, z: float) -> bool:
	return water != null and water.is_wet(x, z)

## A ripple ring spreading from (x, z); does nothing on dry ground.
func add_ripple(x: float, z: float, strength: float = 1.0) -> void:
	if water != null:
		water.add_ripple(x, z, strength)

func detach() -> void:
	set_enabled(false)
	for id in area_flames:
		area_flames[id].queue_free()
	for n in window_nodes:
		n.queue_free()
	area_flames.clear()
	window_nodes.clear()
	queue_free()

# ------------------------------------------------------------------ per frame
func focus_position() -> Vector3:
	if focus_node != null and is_instance_valid(focus_node):
		return focus_node.global_position
	return ground_point(get_viewport().get_camera_3d())

## No follow node: where the camera's centre ray meets the ground (the rig looks at the hero).
static func ground_point(cam: Camera3D) -> Vector3:
	if cam == null:
		return Vector3.ZERO
	var o := cam.global_position
	var dir := -cam.global_transform.basis.z
	if absf(dir.y) < 1e-4:
		return Vector3(o.x, 0, o.z)
	var t := -o.y / dir.y
	return o + dir * t

func _process(dt: float) -> void:
	clock += dt
	var f := focus_position()
	if _on("flames"):
		_fire_acc += dt
		if _fire_acc >= FIRE_STEP:
			_fire_acc -= FIRE_STEP
			brazier_fire.tick(f)
		brazier_fire.advance(dt)
	if _on("mist"):
		mist.tick(dt, f)
	if _on("atmosphere"):
		atmosphere.reduced_motion = reduced_motion
		atmosphere.tick(dt, area, f)
	if _on("water"):
		water.tick(dt)
		if wade:
			_wade(dt, f)

## WorldScene.wadeRipples: the hero's steps ring the water every other 0.15 s tick, one other wader (enemy/thrall) per tick, round robin.
func _wade(dt: float, f: Vector3) -> void:
	_ripple_t -= dt
	if _ripple_t > 0.0:
		return
	_ripple_t = 0.15
	_ripple_cursor += 1
	if focus_node != null and is_instance_valid(focus_node) and _moving(focus_node) and _ripple_cursor % 2 == 0:
		water.add_ripple(f.x, f.z, 0.9)
	var waders: Array = []
	for g in ["enemies", "thralls"]:
		for n in get_tree().get_nodes_in_group(g):
			var b := n as Node3D
			if b == null:
				continue
			var p := b.global_position
			if _moving(b) and absf(p.x - f.x) < 24.0 and absf(p.z - f.z) < 20.0 and water.is_wet(p.x, p.z):
				waders.append(b)
	if waders.is_empty():
		return
	var pick: Node3D = waders[_ripple_cursor % waders.size()]
	water.add_ripple(pick.global_position.x, pick.global_position.z, 0.7)

func _moving(n: Node3D) -> bool:
	var id := n.get_instance_id()
	var p := n.global_position
	if _prev_pos.size() > 512:
		_prev_pos.clear()
	var prev: Vector3 = _prev_pos.get(id, p)
	_prev_pos[id] = p
	return Vector2(p.x - prev.x, p.z - prev.z).length_squared() > 1e-6
