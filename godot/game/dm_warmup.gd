class_name DmWarmup
extends RefCounted
## First-use hitch removal, run once while the world loads (DmGame.start). Without it every first cast of a rite, first enemy type of a
## wave and first sound loaded from disk mid-fight (100-800 ms stalls measured by tests/perf/combat_perf.gd), and the GPU compiled each
## new shader on its first draw on top of that.
##  1. Every creature model and every Binbun effect scene loads on worker threads (the loading screen keeps drawing).
##  2. One pooled instance per effect, and every creature model, is drawn in front of the camera for a few frames under an opaque
##     cover, so the shaders, skinning and particle programs compile now.

const MODELS := "res://assets/slice/models/"
const COVER_TEXT := "Waking the dead..."

## Keeps the loaded resources referenced (ResourceLoader's cache drops what nobody holds).
static var _held: Array = []
static var last_ms := 0


static func _model_paths() -> Array:
	var out: Array = []
	for d in ResourceLoader.list_directory(MODELS):
		if not d.ends_with("/"):
			continue
		for f in ResourceLoader.list_directory(MODELS + d):
			if f.ends_with(".glb") or f.ends_with(".gltf"):
				out.append(MODELS + d + f)
	return out


static func run(game: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	var tree := game.get_tree()
	var cover := _cover(game)
	var binbun: DmFxBinbun = null
	var ids: Array = []
	if game.vfx != null and game.vfx.binbun != null and game.vfx.binbun.enabled:
		binbun = game.vfx.binbun
		ids = DmFxData.data().get("effects", {}).keys()
	var creature_paths: Array = _model_paths().filter(func(p: String) -> bool: return not p.contains("/props/"))
	var paths: Array = creature_paths.duplicate()
	if binbun != null:
		paths.append_array(binbun.scene_paths(ids))
	# 1. threaded loads
	var pending: Array = []
	for p in paths:
		if ResourceLoader.has_cached(p):
			_held.append(ResourceLoader.load(p))
		elif ResourceLoader.load_threaded_request(p, "", true) == OK:
			pending.append(p)
	var deadline := Time.get_ticks_msec() + 60000
	while not pending.is_empty() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
		for p in pending.duplicate():
			var st := ResourceLoader.load_threaded_get_status(p)
			if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				continue
			pending.erase(p)
			if st == ResourceLoader.THREAD_LOAD_LOADED:
				_held.append(ResourceLoader.load_threaded_get(p))
	# 2. draw everything once in front of the camera
	var cam := game.get_viewport().get_camera_3d()
	var at := Vector3(game.player.x, 0.0, game.player.z) if game.player != null else Vector3.ZERO
	if cam != null:
		at = cam.global_position + (-cam.global_transform.basis.z) * 6.0
	var stage := Node3D.new()
	stage.name = "WarmupStage"
	game.world_root.add_child(stage)
	var i := 0
	for p in creature_paths:
		var ps := ResourceLoader.load(p) as PackedScene
		if ps == null:
			continue
		var n := ps.instantiate() as Node3D
		if n == null:
			continue
		stage.add_child(n)
		n.position = at + Vector3((i % 6) - 2.5, 0.0, float(i / 6) * 0.5) * 0.6
		n.scale = Vector3.ONE * 0.3
		for ap in n.find_children("*", "AnimationPlayer", true, false):
			var a := ap as AnimationPlayer
			var names := a.get_animation_list()
			if names.size() > 0:
				a.play(names[0])
		i += 1
	var warmed: Array = binbun.warm(ids, at) if binbun != null else []
	# Enemy bodies: two per kind into the views' pool (reused by every wave), drawn opaque + mid-fade so DmCreatureMat compiles now.
	var bodies: Array = []
	if game.views != null and game.views.has_method("prewarm"):
		game.views.prewarm(2)
		bodies = game.views.warm_bodies(stage, at)
	# Boss views are built on first sight (36 ms+ at the first wave); build them all now, hidden.
	for bid in DmContent.bosses().keys():
		if game.boss_view(String(bid)) != null:
			game.boss_view_hide(String(bid))
	for k in 3:
		await tree.process_frame
	if binbun != null:
		binbun.warm_end(warmed)
	if not bodies.is_empty():
		game.views.warm_bodies_end(bodies)
	stage.queue_free()
	await tree.process_frame
	cover.queue_free()
	last_ms = Time.get_ticks_msec() - t0
	print("DmWarmup: %d models + %d effects + %d pooled bodies in %d ms" % [creature_paths.size(), warmed.size(), bodies.size(), last_ms])


static func _cover(game: Node) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 90
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.015, 0.03, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(bg)
	var label := Label.new()
	label.text = COVER_TEXT
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(0.78, 0.68, 0.95))
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.grow_vertical = Control.GROW_DIRECTION_BOTH
	bg.add_child(label)
	game.add_child(layer)
	return layer
