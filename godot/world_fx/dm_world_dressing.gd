class_name DmWorldDressing
extends Node3D
## Everything the web draws around the static world that the world track left out, as one self-contained node:
##   stained-glass windows + light shafts, candle-flame sprites + brazier fire, far silhouettes (spires/trees/ruins), ground mist, per-area weather
##   (Atmosphere), standing water with ripples + moon glint, the web's bloom. (Occlusion, wing flap, hover and wade ripples live in godot/world + godot/game.)
## Usage (the whole hook):
##     var dressing := DmWorldDressing.attach(builder, hero)      # after builder.build(world); `hero` = any Node3D to follow (optional)
## Per-area pieces are children of the builder's area nodes, so the builder's streaming hides them with their area; global pieces
## (silhouettes, mist, weather, water) live under this node. Nothing in godot/world, main or game is edited: stock stand-ins this replaces
## (plain water planes, the one-sphere flame glow) are hidden, not freed, and come back on set_enabled(false)/detach().
## Per-feature switches (all default on) exist so the perf harness can measure each piece: see `features`.

const FEATURES := ["windows", "flames", "silhouettes", "mist", "atmosphere", "water", "bloom"]

var builder: Node3D
var focus_node: Node3D
var data: Dictionary
var enabled := true
var features := {"windows": true, "flames": true, "silhouettes": true, "mist": true, "atmosphere": true, "water": true, "bloom": true}
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
var _hidden_stock: Array = []        # nodes hidden because the dressing draws them
var _focus_area := ""
var _mist_t := 0.0
var _ripple_t := 0.0
var _ripple_cursor := 0
var _prev_pos: Dictionary = {}       # instance id -> Vector3 (movement detection for wading)
var _bloom_env: Environment

static func attach(b: Node3D, follow: Node3D = null) -> DmWorldDressing:
	var d := DmWorldDressing.new()
	d.name = "WorldDressing"
	d.builder = b
	d.focus_node = follow
	b.add_child(d)
	d.build()
	return d

func build() -> void:
	data = DmWfxData.get_data()
	if data.is_empty():
		push_error("world_fx: godot/data/world_fx/fx.json missing (it is committed; restore it from git)")
		return
	var world: Dictionary = builder.world
	var order: Array = world.order
	var areas: Dictionary = builder.area_nodes
	# windows
	for w in data.windows:
		var id := DmWfxData.nearest_area(world.areas, order, float(w.x), float(w.z))
		window_nodes.append_array(DmWfxWindows.build(areas[id], w))
	# flames
	for id in data.flames:
		var m := DmWfxFlames.build(areas[id], str(id), data.flames[id], candle_off)
		if m != null:
			area_flames[id] = m
	# brazier fire near the focus (WorldView.update)
	brazier_fire = DmWfxBrazierFire.new()
	add_child(brazier_fire)
	brazier_fire.setup(world)
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
	# occlusion + stock replacements + bloom
	_hide_stock()
	_bloom_env = builder.env
	DmWfxBloom.apply(_bloom_env, true)
	_apply_features()

## Master switch (perf A/B): everything off = the stock world as the world track left it.
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
	# stock stand-ins come back when their replacement is off
	for entry in _hidden_stock:
		var feat: String = entry.feature
		entry.node.visible = not _on(feat)
	DmWfxBloom.apply(_bloom_env, _on("bloom"))

## Hide the world track's stand-ins that these pieces replace: plain water planes/puddle quads, the one-sphere flame glow.
func _hide_stock() -> void:
	for id in builder.area_nodes:
		for c in builder.area_nodes[id].get_children():
			if not (c is MeshInstance3D):
				continue
			var mi := c as MeshInstance3D
			var feat := ""
			if mi.mesh is PlaneMesh and absf(mi.position.y - 0.06) < 0.001 and mi.material_override is StandardMaterial3D and absf((mi.material_override as StandardMaterial3D).roughness - 0.16) < 0.001:
				feat = "water"
			elif mi.mesh is QuadMesh and absf(mi.position.y - 0.025) < 0.001 and mi.material_override is StandardMaterial3D and (mi.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color(0.06, 0.07, 0.14, 0.75)):
				feat = "water"
			elif mi.mesh is SphereMesh and absf((mi.mesh as SphereMesh).radius - 0.1) < 0.001 and mi.material_override is StandardMaterial3D and (mi.material_override as StandardMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
				feat = "flames"
			if feat != "":
				_hidden_stock.append({"node": mi, "feature": feat})
				mi.visible = false

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
	for entry in _hidden_stock:
		entry.node.visible = true
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
	if not enabled or data.is_empty():
		return
	var f := focus_position()
	var area: String = builder.area_at(f.x, f.z)
	if area != "" and area != _focus_area:
		_focus_area = area
		var amb: Dictionary = builder.world.areas[area].ambient
		water.set_moon(Color.html(str(amb.moon)))
		water.set_palette(area == "fen")
	if _on("flames"):
		brazier_fire.tick(dt, f)
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
