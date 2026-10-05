extends SceneTree
## Rendered check: godot --rendering-driver opengl3 --path godot --script res://tests/game/labor_shot.gd -- --out=shots/game/labor.png
## (under the renderer lock). The Grave Laborers at their posts in the Sexton's Acre (real world builder, fake api).

class Host extends Node3D:
	var api
	var hero_id := 1
	var builder
	var world_root: Node3D
	var vfx = null
	var audio = null
	var settings := {"reduce_motion": false}
	func emit_game_event(_id: String, _ctx: Dictionary = {}) -> void:
		pass

var out_path := "res://shots/game/labor.png"

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.substr(6)
	_run.call_deferred()

func _run() -> void:
	var T = load("res://tests/game/test_labor.gd")
	var t = T.new()
	var host := Host.new()
	var b := DmWorldBuilder.new()
	root.add_child(b)
	b.build(DmData.world())
	b.set_area("acre")
	host.builder = b
	host.world_root = b
	host.api = T.FakeApi.new()
	root.add_child(host)
	var nodes: Array = DmData.world()["nodes"].filter(func(n: Dictionary) -> bool: return n["area"] == "acre")
	host.api.labor = t.make_view([T.slot_row(0, "coffin_oak", 3600000.0 * 3), T.slot_row(1, "seam_iron", 1000.0), T.slot_row(2, "grave_pauper", 3600000.0 * 9, true), T.slot_row(3, "pool_still", 3600000.0)])
	var lv := DmLaborerViews.new()
	lv.setup(host)
	lv.set_active(true)
	await process_frame
	await process_frame
	var dbg := lv.debug()
	print(dbg)
	var cx := 0.0
	var cz := 0.0
	for d in dbg:
		cx += d["x"]
		cz += d["z"]
	cx /= dbg.size()
	cz /= dbg.size()
	var cam := Camera3D.new()
	cam.fov = 55.0
	root.add_child(cam)
	cam.current = true
	cam.look_at_from_position(Vector3(cx + 4, 9.0, cz + 15.0), Vector3(cx, 1.0, cz))
	for f in 150:
		await process_frame
		lv.update(1.0 / 30.0, cx, cz)
	await RenderingServer.frame_post_draw
	var abs_path := out_path if out_path.begins_with("/") else ProjectSettings.globalize_path("res://").path_join(out_path.trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	root.get_texture().get_image().save_png(abs_path)
	print("saved ", abs_path)
	quit()
