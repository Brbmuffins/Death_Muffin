extends Node
## Autoload QA driver. Inactive unless the game is started with user args:  -- --qa [--shots=<dir>] [--seconds=N]
## (use with `--world-demo`): scripted fight in the Hollow Graves with the real DmGame: a wave of the dead around the hero, the real rites
## cast at the nearest enemy, Exhume for thralls; one screenshot a second; quits after N seconds.

var active := false
var shots := "res://../shots"
var seconds := 20.0
var t := 0.0
var n := 0
var game: DmGame
var _cast_t := 0.0
var _setup := false
var depths_mode := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--qa":
			active = true
		elif a == "--depths":
			depths_mode = true
		elif a.begins_with("--shots="):
			shots = a.substr(8)
		elif a.begins_with("--seconds="):
			seconds = float(a.substr(10))
	set_process(active)

func _process(dt: float) -> void:
	t += dt
	if game == null:
		var m := get_tree().root.get_node_or_null("Main/Game")
		if m != null and m.ready_:
			game = m
		return
	if depths_mode:
		if not _setup and t > 4.0:
			_setup = true
			game.player.teleport(0.0, -2.0)
			game.depths.enter(1)
		if _setup and t > 8.0 and game.sim.enemies.size() > 0 and fmod(t, 1.0) < dt:
			var e: DmSimEnemy = game.sim.enemies.values()[0]
			game.player.teleport(e.x, e.z + 3.0)
			game.input.set_ground(e.x, e.z)
			game.abilities.cast(game.primary, {"x": e.x, "z": e.z, "enemyId": e.id}, game.now_ms)
		if t > float(n + 1):
			n += 1
			DirAccess.make_dir_recursive_absolute(shots)
			get_viewport().get_texture().get_image().save_png("%s/qa_%02d.png" % [shots, n])
		if t > seconds:
			get_tree().quit()
		return
	if not _setup and t > 4.0:
		_setup = true
		game.player.teleport(0.0, 9.0)
		game.player.move_to(0.0, -6.0)
	if _setup and t > 9.0 and game.sim.enemies.size() < 6 and fmod(t, 3.0) < dt:
		for i in 5:
			game.sim.spawn_enemy("robber", "graves", game.player.x + randf_range(-6, 6), game.player.z - randf_range(5, 10), false, false)
	if _setup and t > 9.0:
		_cast_t -= dt
		if _cast_t <= 0.0:
			_cast_t = 0.4
			var best: DmSimEnemy = null
			var bd := 99.0
			for e in game.sim.enemies.values():
				var d: float = Vector2(e.x - game.player.x, e.z - game.player.z).length()
				if d < bd:
					bd = d
					best = e
			if best != null:
				game.input.set_ground(best.x, best.z)
				game.player.face(best.x, best.z)
				game.abilities.cast(game.primary, {"x": best.x, "z": best.z, "enemyId": best.id}, game.now_ms)
				game.p["resource"]["value"] = 100.0
				game.p["hp"] = game.player.max_hp()
				if fmod(t, 4.0) < 0.5:
					game.abilities.cast("exhume", {"x": best.x, "z": best.z}, game.now_ms)
	if t > float(n + 1):
		n += 1
		var img := get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute(shots)
		img.save_png("%s/qa_%02d.png" % [shots, n])
	if t > seconds:
		get_tree().quit()
