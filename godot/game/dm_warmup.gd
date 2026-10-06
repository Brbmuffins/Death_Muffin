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
	var cover := DmLoadingScreen.acquire(game, COVER_TEXT)   # main shows it before the world builds; a bare DmGame (tests) gets its own
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
	cover.set_progress(0.2)
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
	# 3. Tour every area under the cover: a material's shader variant is compiled the first time it is drawn under that lighting
	# (prop lights near or not, moon shadow casting or not), so the world itself, and bodies/effects under each area's lights,
	# compiled on arrival: a fresh PC froze ~2.7 s stepping into the Graves. The stage (bodies + effects) travels with the camera.
	await _tour(game, stage, warmed, at, cover)
	# Effects with no point light on them at all (a breach at an area's dark edge): Godot compiles a separate "no omni light"
	# variant, and only an unlit draw makes it. Back in front of the camera, every point light in the tree hidden.
	if binbun != null:
		var dark: Array = []
		for l in tree.root.find_children("*", "Light3D", true, false):
			if (l is OmniLight3D or l is SpotLight3D) and (l as Light3D).visible:
				(l as Light3D).visible = false
				dark.append(l)
		var cam2 := game.get_viewport().get_camera_3d()
		var at2 := at if cam2 == null else cam2.global_position + (-cam2.global_transform.basis.z) * 6.0
		stage.position = at2 - at
		binbun.rewarm(warmed, at2)
		for k in TOUR_FRAMES:
			await tree.process_frame
		for l in dark:
			if is_instance_valid(l):
				(l as Light3D).visible = true
	if binbun != null:
		binbun.warm_end(warmed)
	if not bodies.is_empty():
		game.views.warm_bodies_end(bodies, stage)
	stage.queue_free()
	await tree.process_frame
	if cover.owned:
		cover.dismiss(false)   # (main's screen stays up through the HUD + panel warm-up, then fades)
	# One more frame so the stage/cover teardown (freeing every warmed model) lands in loading, not in the first played frame (~20 ms).
	await tree.process_frame
	last_ms = Time.get_ticks_msec() - t0
	print("DmWarmup: %d models + %d effects + %d pooled bodies in %d ms" % [creature_paths.size(), warmed.size(), bodies.size(), last_ms])


const TOUR_FRAMES := 3

static func _tour(game: Node3D, stage: Node3D, warmed: Array, at0: Vector3, cover: DmLoadingScreen) -> void:
	var tree := game.get_tree()
	var b = game.builder
	var cam = game.camera
	if b == null or cam == null:
		return
	var flash: OmniLight3D = game.vfx.get("_flash_light") if game.vfx != null else null
	var flash_range := flash.omni_range if flash != null else 9.0
	var stops: Array = []
	for id in DmContent.area_order():
		var r: Dictionary = DmContent.area(String(id))["rect"]
		stops.append([String(DmContent.area(String(id)).get("name", id)), Vector3((float(r["x0"]) + float(r["x1"])) / 2.0, 0.0, (float(r["z0"]) + float(r["z1"])) / 2.0), String(id)])
	var n := 0
	var layer_handles: Array = []
	for s in stops:
		n += 1
		var p: Vector3 = s[1]
		cover.set_text("%s  %s  (%d / %d)" % [COVER_TEXT, s[0], n, stops.size()])
		cover.set_progress(0.2 + 0.6 * float(n - 1) / float(stops.size()))
		cam.snap(p)
		if game.hero_focus != null:
			game.hero_focus.position = p
		b.update_streaming(p.x, p.z)
		b.update_light_lod(p.x, p.z)
		b._shadow_t = 0.0
		b.update_shadow_cells(p.x, p.z, 0.0)
		var at: Vector3 = cam.global_position + (-cam.global_transform.basis.z) * 6.0
		stage.position = at - at0
		if n == 1 and game.vfx != null and game.vfx.prims != null:
			layer_handles = game.vfx.prims.warm_layers(at)
		if game.vfx != null and game.vfx.binbun != null:
			game.vfx.binbun.rewarm(warmed, at)
		# A rehearsal wave (visual only: the views draw enemies the sim does not have): this area's roster + an elite, rising and
		# moving, with their rings/auras and the breach rim, under this area's own lights; the first real wave then compiles nothing.
		var fake := _fake_wave(game, String(s[2]), at, n)
		for k in TOUR_FRAMES:
			if game.views != null and not fake.is_empty():
				game.views.sync(fake, {}, 0.05, p.x, p.z)
			await tree.process_frame
		# Godot compiles a separate variant for "no point light on this object": breaches and the dark edges of an area have no
		# prop light, so draw the same set once more with every point light off.
		var near: int = b.light_near
		b.light_near = 0
		b.update_light_lod(p.x, p.z)
		# Any visible light counts, even at zero energy (the idle flash light, the hero's lantern, elite auras): hide them all.
		var hidden: Array = []
		for l in tree.root.find_children("*", "Light3D", true, false):
			if (l is OmniLight3D or l is SpotLight3D) and (l as Light3D).visible:
				(l as Light3D).visible = false
				hidden.append(l)
		if game.vfx != null and game.vfx.binbun != null:
			game.vfx.binbun.rewarm(warmed, at)
		for k in TOUR_FRAMES:
			if game.views != null and not fake.is_empty():
				game.views.sync(fake, {}, 0.05, p.x, p.z)
			await tree.process_frame
		for l in hidden:
			if is_instance_valid(l):
				(l as Light3D).visible = true
		b.light_near = near
		b.update_light_lod(p.x, p.z)
		if not fake.is_empty():
			game.views.sync({}, {}, 0.05, p.x, p.z)
			for k in 25:
				game.views.sync({}, {}, 0.05, p.x, p.z)   # fade the rehearsal bodies out and back into the pool
		# The shared flash light (waves, big casts) reaches floors/walls/props no prop light does: those materials need their
		# "lit by a point light" variant too, or the first wave in an area compiles it (the Graves froze ~2.5 s on a fresh PC).
		if flash != null:
			flash.position = p + Vector3(0, 3, 0)
			flash.omni_range = 60.0
			flash.light_energy = 1.0
			if game.vfx != null and game.vfx.binbun != null:
				game.vfx.binbun.rewarm(warmed, at)
			for k in TOUR_FRAMES:
				await tree.process_frame
			flash.light_energy = 0.0
			flash.omni_range = flash_range
	for h in layer_handles:
		if h != null:
			h.kill()
	# back to the hero
	var hp := Vector3(game.player.x, 0.0, game.player.z)
	cam.snap(hp)
	if game.hero_focus != null:
		game.hero_focus.position = hp
	b.update_streaming(hp.x, hp.z)
	b.update_light_lod(hp.x, hp.z)
	b._shadow_t = 0.0
	b.update_shadow_cells(hp.x, hp.z, 0.0)
	cover.set_text(COVER_TEXT)


## Enemies for the views only (ids far above the sim's): the area's roster around `at`, the first one elite, half of them rising.
static func _fake_wave(game: Node3D, area: String, at: Vector3, salt: int) -> Dictionary:
	var out := {}
	var def: Dictionary = DmSimData.AREAS.get(area, {})
	var roster: Array = def.get("enemies", [])
	var i := 0
	for r in roster:
		var id := String(r["id"])
		var ed: Dictionary = DmContent.enemies().get(id, {})
		if ed.is_empty():
			continue
		var e := DmSimEnemy.new()
		e.id = 900000 + salt * 100 + i
		e.def = id
		e.area = area
		e.elite = i == 0
		var a := float(i) * 1.3
		e.x = at.x + cos(a) * 2.5
		e.z = at.z + sin(a) * 2.5
		e.facing = a
		e.scale = float(ed.get("scale", 1.0)) * (1.35 if e.elite else 1.0)
		e.maxHp = 100.0
		e.hp = 60.0
		e.radius = float(ed.get("radius", 0.5))
		e.state = "rising" if i % 2 == 1 else "move"
		e.moving = e.state == "move"
		out[e.id] = e
		i += 1
	return out
