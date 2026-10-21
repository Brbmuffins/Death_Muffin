extends SceneTree
## The 3D draw-call measurement (client/next/perf/DRAW-BUDGET.md). A RENDERED run: Forward+ on the software Vulkan driver (lavapipe); a draw-call count does not depend on the GPU,
## only on the camera, the lights and the scene. It builds the budget's scene (`DmDrawScene`: a room's area scene, the game's camera, the Ultra preset's moon, then a Full Party on the
## combat core) and reads the engine's own counters (`Viewport` render info: the main pass and the moon's shadow passes, draw calls and objects) beside what the counted model
## (`DmDrawModel`) says for the same frame, in these phases, each written as JSON lines as it goes (a run cut off by the caller's timeout keeps what it got):
##   1. the world from the camera's place and four places round it, then each group of its geometry hidden alone (props, walls, doors, decals ...) and the moon's shadows off;
##   2. with `--compare=<area scene>`, the same for another version of the room's scene (`git show <rev>:client/areas/graves.tscn` into a file; its lightmap is dropped), to put two layouts side by side;
##   3. a MultiMesh with no instance and one with four, with and without shadows: what each costs;
##   4. the crowd: the groups the crowd shows, every group shown (what a crowd that never hid its empty groups draws) and the crowd node hidden.
##
##   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a -s "-screen 0 1280x720x24" \
##     timeout 300 /home/ubuntu/tools/godot/godot --path client --rendering-driver vulkan --rendering-method forward_plus --resolution 480x270 --fixed-fps 60 \
##     --script res://tools/draw_measure.gd -- --out=<file.jsonl> [--room=graves] [--compare=<scene.tscn>] [--budget=272]
##
## On this VPS the engine takes ~25 s to start, ~30 s to build the world and ~30 s to draw its first frames (the shaders compile on the CPU), then about a second a frame: the run above
## needs ~200 s, so `--budget` (seconds since the start; default 272) drops the later steps before the 300 s timeout. The picture is 16:9 as the benchmark's. Headless it runs the same
## code with every engine count 0 (the model's side can be seen that way).

var out: FileAccess
var budget_s := 272
var room := "graves"
var compare := ""
var stage: DmDrawScene.Stage
var moon: DirectionalLight3D
var headless := false


func _initialize() -> void:
	headless = DisplayServer.get_name() == "headless"
	RenderingServer.render_loop_enabled = false   # nothing is drawn until the scene stands (the first drawn frame of a software Vulkan device takes tens of seconds)
	var path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			path = a.substr(6)
		elif a.begins_with("--room="):
			room = a.substr(7)
		elif a.begins_with("--compare="):
			compare = a.substr(10)
		elif a.begins_with("--budget="):
			budget_s = int(a.substr(9))
	if path != "":
		out = FileAccess.open(path, FileAccess.WRITE)
	emit({"event": "start", "renderer": RenderingServer.get_video_adapter_name(), "window": str(DisplayServer.window_get_size()), "room": room, "compare": compare})
	await process_frame
	await run()
	emit({"event": "done"})
	quit(0)


func emit(d: Dictionary) -> void:
	d["t"] = snappedf(float(Time.get_ticks_msec()) / 1000.0, 0.01)   # since the process started
	var line := JSON.stringify(d)
	print(line)
	if out != null:
		out.store_line(line)
		out.flush()


func late() -> bool:
	return Time.get_ticks_msec() > budget_s * 1000


## The next drawn frame (headless: the next processed one).
func next_frame() -> void:
	if headless:
		await process_frame
	else:
		await RenderingServer.frame_post_draw


## The engine's counters of the frame just drawn.
func read() -> Dictionary:
	var vp := root.get_viewport_rid()
	var d := {}
	for kind: Array in [["main", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE], ["shadow", RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW]]:
		d[kind[0] + "_draws"] = int(RenderingServer.viewport_get_render_info(vp, kind[1], RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
		d[kind[0] + "_objs"] = int(RenderingServer.viewport_get_render_info(vp, kind[1], RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME))
	d["draws"] = d["main_draws"] + d["shadow_draws"]
	return d


func frames_read(n: int) -> Dictionary:
	for i in n:
		await next_frame()
	return read()


## One row: the engine's counters, and the model's for the same records.
func row(what: String, r: Dictionary, recs: Array = [], extra := {}) -> void:
	var d := {"event": "row", "what": what, "r": r}
	if not recs.is_empty():
		var size := root.get_viewport().get_visible_rect().size
		var res := DmDrawModel.count(recs, DmDrawModel.facts(stage, stage.camera, size.x / maxf(1.0, size.y)))
		d["model"] = res["total"]
	d.merge(extra)
	emit(d)


func run() -> void:
	stage = DmDrawScene.build(root, room)
	moon = stage.world.builder.moon
	RenderingServer.directional_shadow_atlas_set_size(1024, true)   # (the draw calls do not depend on the atlas; the software rasteriser does)
	var area := stage.world.get_node("area_%s" % room) as Node3D
	var other: Node3D = null
	if compare != "":
		other = (load(compare) as PackedScene).instantiate() as Node3D
		other.name = area.name
		var lm := other.get_node_or_null("Lightmap")
		if lm != null:
			lm.free()   # (its bake is the room's current scene's)
	emit({"event": "built", "ms": stage.world.build_ms})
	RenderingServer.render_loop_enabled = true
	emit({"event": "first", "r": await frames_read(2)})
	await world_rows("the scene", true)
	if other != null and not late():
		stage.world.remove_child(area)
		stage.world.add_child(other)
		await world_rows("the compared scene", true)
		stage.world.remove_child(other)
		stage.world.add_child(area)
		other.free()
	if not late():
		await multimeshes()
	if not late():
		await crowd()


## The world's draws from the camera's place and round it, then (at the first) each group hidden alone.
func world_rows(label: String, groups_too: bool) -> void:
	var recs := DmDrawModel.records(stage.world, stage)
	var places := {"centre": Vector3.ZERO, "west": Vector3(-12, 0, 0), "east": Vector3(12, 0, 0), "north": Vector3(0, 0, -10), "south": Vector3(0, 0, 10)}
	for place: String in places:
		if late():
			return
		stage.camera.snap(stage.focus + places[place])
		row("%s, camera %s" % [label, place], await frames_read(2), recs)
		if place == "centre" and groups_too:
			moon.shadow_enabled = false
			var no_shadows := await frames_read(2)
			moon.shadow_enabled = true
			row("%s, no moon shadows" % label, no_shadows)
			var names := {}
			for r: Dictionary in recs:
				names[r["grp"]] = true
			var keys := names.keys()
			keys.sort()
			for g: String in keys:
				if late():
					return
				var hit: Array = []
				var st: Array[Node] = [stage.world]
				while not st.is_empty():
					var nd: Node = st.pop_back()
					for c in nd.get_children():
						st.append(c)
					if nd is GeometryInstance3D and (nd as GeometryInstance3D).visible and DmDrawModel.record(nd, stage)["grp"] == g:
						hit.append(nd)
				for n: GeometryInstance3D in hit:
					n.visible = false
				var r := await frames_read(1)
				for n: GeometryInstance3D in hit:
					n.visible = true
				row("%s, hide %s (%d)" % [label, g, hit.size()], r)
	stage.camera.snap(stage.focus)


## A MultiMesh with no instance and one with four, each with and without shadows, added to the world alone: what they cost.
func multimeshes() -> void:
	var mesh := BoxMesh.new()
	var nodes: Array = []
	var names := ["empty, no shadow", "empty, casts", "4 instances, no shadow", "4 instances, casts"]
	for i in 4:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = 16
		for k in 4:
			mm.set_instance_transform(k, Transform3D(Basis(), stage.focus + Vector3(float(i) * 2.0 - 3.0, 1.0, float(k))))
		mm.visible_instance_count = 0 if i < 2 else 4
		mm.custom_aabb = AABB(stage.focus + Vector3(-40, -4, -40), Vector3(80, 18, 80))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if i % 2 == 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = false
		stage.add_child(mmi)
		nodes.append(mmi)
	var none := await frames_read(2)
	for i in 4:
		(nodes[i] as Node3D).visible = true
		var r := await frames_read(2)
		(nodes[i] as Node3D).visible = false
		row("a MultiMesh, " + names[i], r, [], {"main_draws_added": r.main_draws - none.main_draws, "shadow_draws_added": r.shadow_draws - none.shadow_draws,
			"main_objs_added": r.main_objs - none.main_objs, "shadow_objs_added": r.shadow_objs - none.shadow_objs})
	for n: Node in nodes:
		n.free()


## The Full Party on the core, then the crowd's groups as the crowd shows them, every group shown, and the crowd hidden.
func crowd() -> void:
	RenderingServer.render_loop_enabled = false
	var host := DmDrawScene.add_crowd(stage)
	for i in 90:
		await physics_frame
	paused = true   # the picture stays: the groups keep the state the crowd gave them
	RenderingServer.render_loop_enabled = true
	emit({"event": "crowd", "models": host.view.model_slots().size(), "stats": host.view.crowd.stats()})
	var recs := DmDrawModel.records(stage, stage)
	row("the crowd as the crowd shows it", await frames_read(2), recs)
	var groups: Array = []
	for c in host.view.get_children():
		if c is MultiMeshInstance3D:
			groups.append([c, c.visible])
			c.visible = true
	var legacy := recs.duplicate(true)
	for r: Dictionary in legacy:
		if String(r["grp"]).begins_with("crowd"):
			r["vis"] = true
	row("every group shown", await frames_read(2), legacy, {"groups": groups.size()})
	for pair: Array in groups:
		pair[0].visible = pair[1]
	host.view.visible = false
	row("the crowd hidden", await frames_read(2))
	host.view.visible = true
