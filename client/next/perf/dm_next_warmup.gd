class_name DmNextWarmup
extends RefCounted
## GPU first-use warm-up for the rebuilt client (DmNextGame.start, under a cover): DmWarmup's approach on the parts this game draws. Ported
## (client/code.list "Ported"): there are no per-creature nodes to rehearse, so the crowd is warmed with rehearsal rows and the bosses' models stay nodes.
##  1. Every creature model and Binbun effect scene loads on worker threads.
##  2. Every boss model the game serves is drawn in front of the camera (opaque and mid-fade), with every effect (Binbun scenes, decal / flash layers, enemy +
##     boss telegraph shapes) and the gear models, and every crowd model is drawn at three distances (the three levels of detail; the nearest also cast shadows) from
##     rehearsal rows fed straight to the crowd (`DmCrowd.sync_rows`): shaders, skinning and particle programs compile now.
##  3. The area tour: the camera visits the areas this game has loaded (the Hollow Graves so far), the stage (bodies + effects) travels with it. A material's variant is compiled the
##     first time it is drawn under that lighting (prop lights near or not, moon shadow casting or not): each area is drawn lit, then with every point light hidden
##     (Godot's separate "no omni light" variant), then with the shared flash light on.
## The combat core's tick is held while it runs (the host's sync would otherwise forget the rehearsal rows at once); the rows are cleared at the end. The cover is the
## shared art DmLoadingScreen (main's, else acquired here). Costs the loading time only: nothing here survives into play (the stage, the rows and the effect handles are freed).
## Runs for players as today's does (`DmNextGame._wants_warmup`: not headless, not on QA runs; the benchmark forces it). Before 2026-10-17 it ran only in the benchmark, and play
## compiled every effect on its first use (warbogar: "Reaper lags out hard on first time VFX rendering").

const TOUR_FRAMES := 3
const ROW_ID := 900000                 ## ids of the rehearsal rows (the core's ids are small)
const ROW_GAPS := [0.0, 26.0, 56.0]    ## metres from the camera's focus: the three levels of detail (32 m and 60 m from the camera, which hangs up and back)
const SHROUDED := 256                  ## CrowdBody flag BF_SHROUDED: the Shrouded ward is up, the body eases to see-through and is drawn in its model's fade group

static var last_ms := 0
static var models := 0
static var effects := 0
static var crowd_rows := 0
static var shots := 0                  ## the shots (needle, orb, sprite) and beams drawn under the cover


## Every boss body the game draws as a node: [{slug, opts}] for the bosses of `served` areas (the other bosses' models are not in this build).
static func specs(served: Array) -> Array:
	var out: Array = []
	var seen := {}
	for bid in DmContent.get_export("bosses", "BOSS_IDS"):
		var b: Dictionary = DmContent.boss(String(bid))
		if not served.has(String(b.get("area", ""))):
			continue
		var slug := String(b["modelSlug"])
		if not seen.has(slug):
			seen[slug] = true
			out.append({"slug": slug, "opts": {"hitstop": true}})
	return out


## Slugs of the bodies drawn as nodes (tests: each must be loaded after the warm-up).
static func creature_slugs(served: Array) -> Array:
	return specs(served).map(func(sp: Dictionary) -> String: return String(sp["slug"]))


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
	var host: DmCoreHost = game.core_host
	game.set_process(false)   # the tour moves the camera itself
	host.set_physics_process(false)   # the host's tick would sync the (empty) core into the crowd and forget the rehearsal rows
	# 1. threaded loads (the cover keeps drawing)
	var paths: Array = DmWarmup._model_paths().filter(func(p: String) -> bool: return not p.contains("/props/"))
	if binbun != null:
		paths.append_array(binbun.scene_paths(ids))
	var pending: Array = []
	for p in paths if DisplayServer.get_name() != "headless" else []:   # (headless has no GPU to warm, and its dummy renderer fails on loads from worker threads: texture_2d_initialize "t is null", intermittently)
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
	var bodies := _bodies(stage, at0, game.bosses.served_areas)
	for k in 2:   # the gear models' two material variants (the model's own, and the emissive tier dress), drawn once so they compile now
		var w := DmGearModels.weapon("staff", ["bone", "hell"][k])
		if w != null:
			stage.add_child(w)
			w.position = at0 + Vector3(-1.2 + 0.6 * k, 0.9, 0.0)
	var scythe := DmGearProps.scythe_model()   # the Reaper's scythe: worn, and the spinning copy Scythe Throw makes
	if scythe != null:
		stage.add_child(scythe)
		scythe.position = at0 + Vector3(0.6, 0.9, 0.0)
		var sp := DmModels.BASE + "models/props/%s.glb" % DmGearProps.SCYTHE_FILE
		DmWarmup.hold(sp, load(sp))   # kept loaded: every throw instances it again
	var warmed: Array = binbun.warm(ids, at0) if binbun != null else []
	var layer_handles: Array = vfx.prims.warm_layers(at0) if vfx != null and vfx.prims != null else []
	shots = 0
	if vfx != null and vfx.prims != null:
		var beams: Array = vfx.prims.warm_shots(at0)
		layer_handles.append_array(beams)
		shots = 3 + beams.size()
	var hero_look := _hero_creature(game)   # the hero's own see-through variant (Wraith Walk's phantom) compiles now, not on the first rush
	if hero_look != null:
		hero_look.set_opacity(0.45)
	game.enemy_fx.warm(at0)
	game.bosses.warm(at0)
	crowd_rows = _feed_crowd(game, cam)
	for k in 3:
		await tree.process_frame
		_feed_crowd(game, cam)
	# 3. the area tour (+ the "no point light" variant at each stop)
	await _tour(game, stage, bodies, warmed, at0, cover)
	if hero_look != null:
		hero_look.set_opacity(1.0)
	if binbun != null:
		binbun.warm_end(warmed)
	for h in layer_handles:
		if h != null:
			h.kill()
	for b in bodies:
		b["c"].dispose()
	stage.queue_free()
	if host.view != null:
		host.view.clear()   # the rehearsal rows go; the core's own bodies come with its next sync
	var mine: Dictionary = DmContent.discipline(String(game.local_body().discipline_id)) if game.local_body() != null else {}
	# the kits of disciplines nobody can pick are freed; the playable ones stay resident (no first-use load), and so does the hero's own legendary-set body
	DmWarmup.release_unused_heroes([String(mine.get("modelSlug", "")), DmGearModels.legendary_of_discipline(String(game.local_body().discipline_id) if game.local_body() != null else "")])
	await tree.process_frame
	if cover.owned:
		cover.dismiss(false)   # (main's screen stays up through the HUD + panel warm-up, then fades)
	host.set_physics_process(true)
	game.set_process(true)
	await tree.process_frame   # the stage / cover teardown lands in loading, not in the first played frame
	models = bodies.size()
	effects = warmed.size()
	last_ms = Time.get_ticks_msec() - t0
	print("DmNextWarmup: %d bodies + %d effects + %d crowd rows in %d ms" % [models, effects, crowd_rows, last_ms])


## The local hero's model (its avatar's creature), or null before the avatar exists.
static func _hero_creature(game: DmNextGame) -> DmCreature:
	var b := game.local_body()
	var av: Variant = b.get("avatar") if b != null else null
	return (av as DmAvatar).c if av is DmAvatar and is_instance_valid(av) else null


## One boss body per spec plus a mid-fade pass of each (DmCreatureMat's opaque and fade variants).
## [{c: DmCreature, slug}].
static func _bodies(stage: Node3D, at: Vector3, served: Array) -> Array:
	var out: Array = []
	var i := 0
	for sp in specs(served):
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
			out.append({"c": c, "slug": sp["slug"]})
			i += 1
	return out


## The rehearsal rows into the crowd: every model slot as an enemy and as a thrall, standing, at three distances along the camera's ground heading (the nearest
## also cast shadows, the farther two use the coarser meshes). The enemy rows stand under the Shrouded ward (`DmCrowd`'s shrouded flag, 256): they ease into their model's
## fade group, so the alpha shader and each model's fade material are drawn now too. Fed again every frame, so the rows stay alive; returns how many.
static func _feed_crowd(game: DmNextGame, cam: DmCameraRig) -> int:
	var view: CrowdView = game.core_host.view
	if view == null or view.crowd == null:
		return 0
	var fwd := Vector3(-cam.global_transform.basis.z.x, 0.0, -cam.global_transform.basis.z.z)
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.FORWARD
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var focus := Vector3(game.camera.global_position.x, 0.0, game.camera.global_position.z) + fwd * 16.0   # (the camera hangs back: its focus is ahead)
	view.focus = Vector2(focus.x, focus.z)   # the nearest rows cast shadows
	var bi := PackedInt32Array()
	var bf := PackedFloat32Array()
	var id := ROW_ID
	var col := 0
	for slot in view.model_slots().values():
		for gap in ROW_GAPS:
			for kind in 2:
				var p: Vector3 = focus + fwd * float(gap) + side * (float(col % 12) - 5.5) * 1.4 + fwd * floorf(col / 12.0) * 1.4
				bi.append_array(PackedInt32Array([id, kind, int(slot), 1, SHROUDED if kind == 0 else 0, 0, 0, 0]))   # state 1: idle (an enemy's IDLE, a thrall's IDLE); no glow
				bf.append_array(PackedFloat32Array([p.x, p.z, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0]))
				id += 1
				col += 1
	view.crowd.sync_rows(bi, bf, PackedFloat32Array(), PackedInt32Array(), PackedFloat32Array())
	return id - ROW_ID


static func _tour(game: DmNextGame, stage: Node3D, bodies: Array, warmed: Array, at0: Vector3, cover: DmLoadingScreen) -> void:
	var tree := game.get_tree()
	var cam: DmCameraRig = game.camera
	var vfx := game.get_node_or_null("/root/Vfx")
	var binbun: DmFxBinbun = vfx.binbun if vfx != null and vfx.binbun != null and vfx.binbun.enabled else null
	var flash: OmniLight3D = vfx.get("_flash_light") if vfx != null else null
	var flash_range := flash.omni_range if flash != null else 9.0
	var order: Array = game.world.loaded
	var home := game.local_body().global_position if game.local_body() != null else Vector3.ZERO
	var n := 0
	for id in order:
		n += 1
		var r: Dictionary = game.world.area_rect(String(id))
		var p := Vector3((float(r["x0"]) + float(r["x1"])) / 2.0, 0.0, (float(r["z0"]) + float(r["z1"])) / 2.0)
		cover.set_text("%s  %s  (%d / %d)" % [DmWarmup.COVER_TEXT, String(DmContent.area(String(id)).get("name", id)), n, order.size()])
		cover.set_progress(0.2 + 0.6 * float(n - 1) / float(order.size()))
		_focus(game, p)
		var at := cam.global_position + (-cam.global_transform.basis.z) * 6.0
		stage.position = at - at0
		if binbun != null:
			binbun.rewarm(warmed, at)
		for k in TOUR_FRAMES:
			_feed_crowd(game, cam)
			await tree.process_frame
		# "No point light on this object" is a separate variant (a breach at an area's dark edge): same set again with every light off.
		var hidden: Array = []
		for l in tree.root.find_children("*", "Light3D", true, false):
			if (l is OmniLight3D or l is SpotLight3D) and (l as Light3D).visible:
				(l as Light3D).visible = false
				hidden.append(l)
		if binbun != null:
			binbun.rewarm(warmed, at)
		for k in TOUR_FRAMES:
			_feed_crowd(game, cam)
			await tree.process_frame
		for l in hidden:
			if is_instance_valid(l):
				(l as Light3D).visible = true
		# The shared flash light (waves, big casts) reaches floors / walls / props no prop light does: their "lit by a point light" variant.
		if flash != null:
			flash.position = p + Vector3(0, 3, 0)
			flash.omni_range = 60.0
			flash.light_energy = 1.0
			flash.visible = true
			if binbun != null:
				binbun.rewarm(warmed, at)
			for k in TOUR_FRAMES:
				_feed_crowd(game, cam)
				await tree.process_frame
			flash.light_energy = 0.0
			flash.visible = false
			flash.omni_range = flash_range
	_focus(game, home)
	cover.set_text(DmWarmup.COVER_TEXT)


## Camera and the world's focus follow `p` (what DmNextWorld.update does each frame; the area scenes have no streaming or light cells to move).
static func _focus(game: DmNextGame, p: Vector3) -> void:
	game.camera.snap(p)
	game.world.focus.position = Vector3(p.x, 0.0, p.z)
