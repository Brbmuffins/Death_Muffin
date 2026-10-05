extends SceneTree
## Regression: quitting with live effects must exit 0 (was a segfault in teardown: Vfx follow/getter closures called into a freed game).
## Plays a burst of every Binbun effect + the Effects.ts primitives in a real offline game, then quits the way main.gd does
## (game still alive), after freeing the game first (leaving the world); `-- --alive` quits with the game alive.
## godot --headless --path godot --script res://tests/game/exit_run.gd [-- --alive]

## Like DmEventFx: a game child whose effects follow through a lambda that reads its own members (freed with the game).
class Owner:
	extends Node
	var world: Object = null

	func start(vfx: Node, p: Vector3) -> void:
		world = get_parent().get("sim")
		vfx.play("censer_incense", p, {"duration": 60.0, "follow": func() -> Variant: return Vector3(world.time, 0.0, 0.0)})


func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var freed := not OS.get_cmdline_user_args().has("--alive")
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("exit%d" % (Time.get_ticks_usec() % 100000), "e@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var game := DmGame.new()
	root.add_child(game)
	await game.start(c.data, api, {"visual": true, "persist": false, "local_progress": true, "seed": 5})
	var vfx: Node = root.get_node("Vfx")
	var p: Vector3 = Vector3(game.player.x, 0.0, game.player.z)
	var n := 0
	for id in DmFxData.catalog("effects"):
		vfx.play(String(id), p + Vector3(float(n % 7) - 3.0, 0.0, float(n / 7) - 3.0), {"duration": 30.0})
		n += 1
	var owner_n := Owner.new()
	game.add_child(owner_n)
	owner_n.start(vfx, p)
	vfx.emit({"x": p.x, "y": 0.5, "z": p.z, "count": 40, "color": 0xffcc66, "spread": 1.0, "speed": 2.0, "up": 2.0, "life": 2.0, "size": 0.2})
	vfx.emit_smoke({"x": p.x, "y": 0.5, "z": p.z, "count": 10, "color": 0x444444})
	vfx.decal({"tex": "ring", "color": 0xd9a441, "x": p.x, "z": p.z, "r": 3.0, "duration": 5.0, "opacity": 1.0})
	vfx.decal({"tex": "glow", "color": 0xd9a441, "x": p.x, "z": p.z, "r": 3.0, "duration": 1e9, "opacity": 1.0, "follow": func() -> Variant: return Vector3(game.player.x, 0, game.player.z)})
	vfx.spike_ring(p.x, p.z, 4.0, 8)
	vfx.light_flash(p, Color.WHITE, 1.0, 0.5)
	for i in 30:
		game.tick(1.0 / 30.0)
		await process_frame
	print("effects playing: ", vfx.binbun_count(), " of ", n)
	if freed:
		game.queue_free()
		for i in 3:
			await process_frame
	print("1 passed, 0 failed")
	quit(0)
