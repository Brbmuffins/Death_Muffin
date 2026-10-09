class_name DmNextWarmup
extends RefCounted
## GPU first-use warm-up for the rebuild (DmNextGame.start, under a cover): DmWarmup's approach on the next game's parts.
##  1. Every creature model and Binbun effect scene loads on worker threads.
##  2. Every enemy kind (normal, elite look, mid-fade), thrall body and boss model is drawn in front of the camera, with every effect
##     (Binbun scenes, decal / flash layers, enemy + boss telegraph shapes), so shaders, skinning and particle programs compile now.
##  3. The area tour: the camera visits all 13 areas, the stage (bodies + effects) travels with it. A material's variant is compiled the
##     first time it is drawn under that lighting (prop lights near or not, moon shadow casting or not): each area is drawn lit, then with
##     every point light hidden (Godot's separate "no omni light" variant), then with the shared flash light on.
## The cover is the shared art DmLoadingScreen (main's, else acquired here). Costs the loading time only: nothing here survives into play (the stage and the effect handles are freed).

const TOUR_FRAMES := 3

static var last_ms := 0
static var models := 0
static var effects := 0


## What an enemy kind is drawn with: its scene's model slug (the sac, the deacon: the def names none), else the def's, else the robber's,
## and DmEnemy.look_options() (wings, tint, fallback model: each is a different creature shader or model).
static func enemy_look(id: String, elite: bool) -> Dictionary:
	var slug := String(DmSimData.ENEMIES.get(id, {}).get("modelSlug", "grave_robber"))
	var o := {"hitstop": true}
	var path := "res://enemies/%s.tscn" % id
	if ResourceLoader.exists(path):
		var inst := (load(path) as PackedScene).instantiate() as DmEnemy
		inst.elite = elite
		if inst.model_slug != "":
			slug = inst.model_slug
		o = inst.look_options()
		inst.free()
	return {"slug": slug, "opts": o}


## Every distinct body the next game draws: [{slug, opts, areas}] (areas = the areas whose waves use it; [] = every stop). Enemy kinds
## normal and elite, thrall bodies (gear tint + rim, spectral wraith, legion models), bosses.
static func specs() -> Array:
	var out: Array = []
	var seen := {}
	var add := func(slug: String, opts: Dictionary, areas: Array) -> void:
		var key := slug + str(opts.hash())
		if not seen.has(key):
			seen[key] = true
			out.append({"slug": slug, "opts": opts, "areas": areas})
	var roster := {}   # enemy id -> [area]
	for a in DmContent.area_order():
		var ids: Array = []
		for e in DmSimData.AREAS.get(String(a), {}).get("enemies", []):
			ids.append(String(e["id"]))
		for th in DmSimData.WAVE_THEMES.get(String(a), []):
			for e in th["roster"]:
				ids.append(String(e["id"]))
		for id in ids:
			roster[id] = roster.get(id, [])
			if not (roster[id] as Array).has(String(a)):
				roster[id].append(String(a))
	for id in DmSimData.ENEMIES:
		for elite in [false, true]:
			var l := enemy_look(String(id), elite)
			add.call(l["slug"], l["opts"], roster.get(String(id), []))
	for k in DmEntityViews.THRALL_SLUG:
		var slug := String(DmEntityViews.THRALL_SLUG[k])
		add.call(slug, {"gear_tint": DmEntityViews.KIT_BODIES.has(k), "tint": 0xf4ecff, "emissive": 0x1f8f86, "emissive_intensity": 0.2, "rim": {"color": 0xd9a441, "strength": 1.2}}, [])
		if k == "wraith":
			add.call(slug, {"spectral": true, "emissive": 0x8f9ed1, "emissive_intensity": 1.1}, [])
	for lid in DmEntityViews.LEGION:
		add.call(String(DmEntityViews.LEGION[lid].slug), {"gear_tint": false, "tint": 0xf4ecff, "emissive": 0x1f8f86, "emissive_intensity": 0.2, "rim": {"color": 0xd9a441, "strength": 1.2}}, [])
	for bid in DmContent.get_export("bosses", "BOSS_IDS"):
		add.call(String(DmContent.boss(String(bid))["modelSlug"]), {"hitstop": true}, [])
	return out


## Slugs the next game draws (tests: each must be loaded after the warm-up).
static func creature_slugs() -> Array:
	var seen := {}
	for sp in specs():
		seen[sp["slug"]] = true
	return seen.keys()


static func run(game: DmNextGame) -> void:
	var t0 := Time.get_ticks_msec()
	var tree := game.get_tree()
	var vfx := game.get_node_or_null("/root/Vfx")
	var binbun: DmFxBinbun = null
	var ids: Array = []
	if vfx != null and vfx.binbun != null and vfx.binbun.enabled:
		binbun = vfx.binbun
		ids = DmFxData.data().get("effects", {}).keys()
	var cover := DmLoadingScreen.acquire(game, DmWarmup.COVER_TEXT)   # main's art screen when present, else our own (tests)
	game.set_process(false)   # the tour moves the camera itself
	# 1. threaded loads (the cover keeps drawing)
	var paths: Array = DmWarmup._model_paths().filter(func(p: String) -> bool: return not p.contains("/props/"))
	if binbun != null:
		paths.append_array(binbun.scene_paths(ids))
	var pending: Array = []
	for p in paths:
		if ResourceLoader.has_cached(p):
			DmWarmup.hold(p, ResourceLoader.load(p))
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
				DmWarmup.hold(p, ResourceLoader.load_threaded_get(p))
	# 2. draw everything once in front of the camera
	var cam: DmCameraRig = game.camera
	var at0 := cam.global_position + (-cam.global_transform.basis.z) * 6.0
	var stage := Node3D.new()
	stage.name = "WarmupStage"
	game.add_child(stage)
	var bodies := _bodies(stage, at0)
	var warmed: Array = binbun.warm(ids, at0) if binbun != null else []
	var layer_handles: Array = vfx.prims.warm_layers(at0) if vfx != null and vfx.prims != null else []
	game.enemy_fx.warm(at0)
	game.bosses.warm(at0)
	for k in 3:
		await tree.process_frame
	# 3. the area tour (+ the "no point light" variant at each stop)
	await _tour(game, stage, bodies, warmed, at0, cover)
	if binbun != null:
		binbun.warm_end(warmed)
	for h in layer_handles:
		if h != null:
			h.kill()
	for b in bodies:
		b["c"].dispose()
	stage.queue_free()
	var mine: Dictionary = DmContent.discipline(String(game.local_body().discipline_id)) if game.local_body() != null else {}
	DmWarmup.release_unused_heroes([String(mine.get("modelSlug", ""))])   # the kits of disciplines nobody can pick; the playable ones stay resident (no first-use load)
	await tree.process_frame
	if cover.owned:
		cover.dismiss(false)   # (main's screen stays up through the HUD + panel warm-up, then fades)
	game.set_process(true)
	await tree.process_frame   # the stage / cover teardown lands in loading, not in the first played frame
	models = bodies.size()
	effects = warmed.size()
	last_ms = Time.get_ticks_msec() - t0
	print("DmNextWarmup: %d bodies + %d effects in %d ms" % [models, effects, last_ms])


## One creature per spec plus a mid-fade pass of each (DmCreatureMat's opaque and fade variants).
## [{c: DmCreature, slug, areas: Array}] (areas = who may show it; [] = the first stop only).
static func _bodies(stage: Node3D, at: Vector3) -> Array:
	var out: Array = []
	var i := 0
	for sp in specs():
		for fade in [false, true]:
			var c := DmCreature.new(String(sp["slug"]), (sp["opts"] as Dictionary).duplicate(true))
			if c.root == null:
				continue
			stage.add_child(c.root)
			c.root.position = at + Vector3((i % 10) - 4.5, 0.0, float(i / 10) * 0.5) * 0.5
			c.root.scale = Vector3.ONE * 0.3
			if fade:
				c.set_opacity(0.5)
			if c.ap != null:
				var names := c.ap.get_animation_list()
				if names.size() > 0:
					c.ap.play(names[0])
			c.update(0.016)
			out.append({"c": c, "slug": sp["slug"], "areas": sp["areas"]})
			i += 1
	return out


static func _tour(game: DmNextGame, stage: Node3D, bodies: Array, warmed: Array, at0: Vector3, cover: DmLoadingScreen) -> void:
	var tree := game.get_tree()
	var b: DmWorldBuilder = game.builder
	var cam: DmCameraRig = game.camera
	if b == null:
		return
	var vfx := game.get_node_or_null("/root/Vfx")
	var binbun: DmFxBinbun = vfx.binbun if vfx != null and vfx.binbun != null and vfx.binbun.enabled else null
	var flash: OmniLight3D = vfx.get("_flash_light") if vfx != null else null
	var flash_range := flash.omni_range if flash != null else 9.0
	var order: Array = DmContent.area_order()
	var home := game.local_body().global_position if game.local_body() != null else Vector3.ZERO
	var n := 0
	for id in order:
		n += 1
		var r: Dictionary = DmContent.area(String(id))["rect"]
		var p := Vector3((float(r["x0"]) + float(r["x1"])) / 2.0, 0.0, (float(r["z0"]) + float(r["z1"])) / 2.0)
		cover.set_text("%s  %s  (%d / %d)" % [DmWarmup.COVER_TEXT, String(DmContent.area(String(id)).get("name", id)), n, order.size()])
		cover.set_progress(0.2 + 0.6 * float(n - 1) / float(order.size()))
		_focus(game, p)
		var at := cam.global_position + (-cam.global_transform.basis.z) * 6.0
		stage.position = at - at0
		# Only this area's roster shows after the first stop (the first compiled every body).
		for bd in bodies:
			var show: bool = n == 1 or (bd["areas"] as Array).has(String(id))
			(bd["c"] as DmCreature).root.visible = show
		if binbun != null:
			binbun.rewarm(warmed, at)
		for k in TOUR_FRAMES:
			await tree.process_frame
		# "No point light on this object" is a separate variant (a breach at an area's dark edge): same set again with every light off.
		var near := b.light_near
		b.light_near = 0
		b.update_light_lod(p.x, p.z)
		var hidden: Array = []
		for l in tree.root.find_children("*", "Light3D", true, false):
			if (l is OmniLight3D or l is SpotLight3D) and (l as Light3D).visible:
				(l as Light3D).visible = false
				hidden.append(l)
		if binbun != null:
			binbun.rewarm(warmed, at)
		for k in TOUR_FRAMES:
			await tree.process_frame
		for l in hidden:
			if is_instance_valid(l):
				(l as Light3D).visible = true
		b.light_near = near
		b.update_light_lod(p.x, p.z)
		# The shared flash light (waves, big casts) reaches floors / walls / props no prop light does: their "lit by a point light" variant.
		if flash != null:
			flash.position = p + Vector3(0, 3, 0)
			flash.omni_range = 60.0
			flash.light_energy = 1.0
			if binbun != null:
				binbun.rewarm(warmed, at)
			for k in TOUR_FRAMES:
				await tree.process_frame
			flash.light_energy = 0.0
			flash.omni_range = flash_range
	for bd in bodies:
		(bd["c"] as DmCreature).root.visible = true
	_focus(game, home)
	cover.set_text(DmWarmup.COVER_TEXT)


## Camera, dressing focus and the builder's streaming / light / shadow cells all follow `p` (what DmNextWorld.update does each frame).
static func _focus(game: DmNextGame, p: Vector3) -> void:
	game.camera.snap(p)
	game.world.focus.position = Vector3(p.x, 0.0, p.z)
	var b: DmWorldBuilder = game.builder
	b.update_streaming(p.x, p.z)
	b.update_light_lod(p.x, p.z)
	b._shadow_t = 0.0
	b.update_shadow_cells(p.x, p.z, 0.0)

