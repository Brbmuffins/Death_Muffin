extends Node
## Autoload QA driver. Inactive unless the game is started with user args:  -- --qa [--shots=<dir>] [--seconds=N] [--shot-plan=<plan.json>]
## (use with `--world-demo`): scripted fight in the Hollow Graves with the real DmGame: a wave of the dead around the hero, the real rites
## cast at the nearest enemy, Exhume for thralls; one screenshot a second; quits after N seconds.

var active := false
var shots := "res://../shots"
var seconds := 20.0
var t := 0.0
var n := 0
var game: DmGame
var nxt: DmNextGame   ## the rebuild (`-- --next`): same scripted fight, driven through its own seams (director.spawn, DmNextInput.cast_at)
var _cast_t := 0.0
var _setup := false
var depths_mode := false
var boss_id := ""
var plan_path := ""   ## --shot-plan=<abs json>: UI shot plan (main/qa_ui_shots.gd) instead of the fight

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--qa":
			active = true
		elif a.begins_with("--boss="):
			boss_id = a.substr(7)
		elif a == "--depths":
			depths_mode = true
		elif a.begins_with("--shot-plan="):
			plan_path = a.substr(12)
		elif a.begins_with("--shots="):
			shots = a.substr(8)
		elif a.begins_with("--seconds="):
			seconds = float(a.substr(10))
	set_process(active)

func _process(dt: float) -> void:
	t += dt
	if nxt != null:
		_process_next(dt)
		return
	if game == null:
		var m := get_tree().root.get_node_or_null("Main/Game")
		if m != null and m.ready_:
			game = m
		else:
			var nm := get_tree().root.get_node_or_null("Main/NextGame")
			if nm != null and nm.ready_:
				nxt = nm
		return
	if plan_path != "":
		if game.ui == null or game.ui.warming or DmLoadingScreen.current != null or t < 3.0:
			return
		set_process(false)
		DmQaUiShots.run(self, game, plan_path, shots)
		return
	if boss_id != "":
		var def: Dictionary = DmContent.boss(boss_id)
		if not _setup and t > 4.0:
			_setup = true
			var ar: Dictionary = def["arena"]
			game.prog.local["shards"] = 50
			game.character["level"] = 30
			game.refresh_stats()
			game.p["x"] = float(ar["x"])
			game.p["z"] = float(ar["z"]) + float(ar["r"]) * 0.5
			game.p["area"] = def["area"]
			game.camera.snap(Vector3(game.player.x, 0, game.player.z))
			game.actions.summon_boss_normal(boss_id)
		if _setup:
			game.p["hp"] = game.player.max_hp()
			game.p["resource"]["value"] = 100.0
			_cast_t -= dt
			if _cast_t <= 0.0 and game.sim.boss.state.active:
				_cast_t = 0.5
				var b = game.sim.boss.state
				game.input.set_ground(b.x, b.z)
				game.abilities.cast(game.primary, {"x": b.x, "z": b.z, "boss": true}, game.now_ms)
				game.abilities.cast("miasma", {"x": b.x, "z": b.z, "boss": true}, game.now_ms)
		if t > float(n + 1):
			n += 1
			DirAccess.make_dir_recursive_absolute(shots)
			get_viewport().get_texture().get_image().save_png("%s/qa_%02d.png" % [shots, n])
		if t > seconds:
			get_tree().quit()
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


## The rebuild's scripted fight (the default branch above, on DmNextGame): the hero walks to the Graves, a pack of robbers keeps arriving, the primary
## rite is cast at the nearest one every 0.4 s, Exhume now and then; hp / essence are topped up. Same screenshots and quit rule. Runs only with `--qa`;
## a few timers per second, nothing per frame beyond the clock.
func _process_next(dt: float) -> void:
	var b := nxt.local_body()
	if b == null:
		return
	if not _setup and t > 4.0:
		_setup = true
		b.teleport(Vector3(0.0, 0.0, 9.0))
	if _setup and t > 9.0:
		var foes: Array = nxt.director.enemies.values().filter(func(e: Variant) -> bool: return is_instance_valid(e))
		var ids: Dictionary = {}
		for k in nxt.director.enemies:
			ids[nxt.director.enemies[k]] = int(k)
		if foes.size() < 6 and fmod(t, 3.0) < dt:
			for i in 5:
				nxt.director.spawn("robber", b.position + Vector3(randf_range(-6.0, 6.0), 0.0, -randf_range(5.0, 10.0)))
		_cast_t -= dt
		if _cast_t <= 0.0:
			_cast_t = 0.4
			var best: DmEnemy = null
			var bd := 99.0
			for e in foes:
				var d := Vector2(e.position.x - b.position.x, e.position.z - b.position.z).length()
				if d < bd:
					bd = d
					best = e
			if best != null:
				var slot := 5 if fmod(t, 4.0) < 0.5 else 0
				nxt.input.cast_at(slot, Vector3(best.position.x, 0.0, best.position.z), int(ids.get(best, 0)), false)
				var caster := b.get_node_or_null("Rites") as DmRiteCaster
				if caster != null:
					caster.p["resource"]["value"] = caster.p["resource"]["max"]
				b.heal(1e6)
	if t > float(n + 1):
		n += 1
		var vp := get_viewport()
		var tex := vp.get_texture() if vp != null else null   # null on a headless run: nothing to shoot, the fight still runs
		var img := tex.get_image() if tex != null else null
		if img != null:
			DirAccess.make_dir_recursive_absolute(shots)
			img.save_png("%s/qa_%02d.png" % [shots, n])
	if t > seconds:
		get_tree().quit()
