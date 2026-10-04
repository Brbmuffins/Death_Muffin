extends Node
## Autoload QA driver. Inactive unless the game is started with user args:  -- --qa [--shots=<dir>] [--seconds=N]
## Scripted run: screenshot the Chapterhouse at spawn, walk through the door into the Graves, spawn a wave, kill some with the hero's
## real bolt, raise thralls with Exhume, screenshot the mid-fight and the F3 overlay, write a JSON perf summary, quit.

var active := false
var shots := "res://../shots"
var t := 0.0
var step := 0
var main: DmMain
var step_t := 0.0
var _spawned := false
var tour := false
var tour_i := 0
var tour_ids: Array = []
var tour_placed := false
var gate := ""

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--qa":
			active = true
		elif a == "--tour":
			tour = true
		elif a.begins_with("--gate="):
			gate = a.substr(7)
			tour = true
		elif a.begins_with("--shots="):
			shots = a.substr(8)
	set_process(active)
	if active:
		DirAccess.make_dir_recursive_absolute(shots)
		print("[qa] active, shots -> ", shots)

func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var p := "%s/%s.png" % [shots, name]
	img.save_png(p)
	print("[qa] shot ", p, " ", img.get_size())

## --tour: break every seal, visit each area (at its centre, or a spot the web uses), screenshot it, quit.
func _tour(dt: float) -> void:
	var w := main.world
	if gate != "":
		# One shot of a sealed gate: stand 6 m in front of it on the room side, seals left as they are by default.
		if step_t > 2.5:
			_shot("gate_%s" % gate)
			get_tree().quit()
		elif not tour_placed:
			tour_placed = true
			for d in w.doors:
				if d.id == gate:
					var ra: Dictionary = w.areas[d.a].rect
					var dc := Vector3(d.cx, 0, d.cz)
					var toward := Vector3((ra.x0 + ra.x1) / 2.0 - d.cx, 0, (ra.z0 + ra.z1) / 2.0 - d.cz)
					toward = Vector3(0, 0, signf(toward.z)) if d.axis == "z" else Vector3(signf(toward.x), 0, 0)
					var p := dc + toward * 5.0
					main.hero.teleport(p)
					main.cam.snap(p)
					main.builder.update_streaming(p.x, p.z)
		return
	if tour_ids.is_empty():
		tour_ids = w.order.duplicate()
		main.builder.open_all()
		step_t = 0.0
	if tour_i >= tour_ids.size():
		print("[qa] tour done")
		get_tree().quit()
		return
	var id: String = tour_ids[tour_i]
	var a: Dictionary = w.areas[id]
	if not tour_placed:
		tour_placed = true
		var r: Dictionary = a.rect
		var p := Vector3((r.x0 + r.x1) / 2.0, 0, (r.z0 + r.z1) / 2.0)
		if id == "chapterhouse":
			p = Vector3(0, 0, 24)
		elif id == "depths":
			p = Vector3(w.depths.start.x, 0, w.depths.start.z)
		p = main.builder.nav_closest(p)
		main.hero.teleport(p)
		main.cam.snap(p)
		main.builder.update_streaming(p.x, p.z)
	if step_t > 2.0:
		_shot("area_%02d_%s" % [tour_i, id])
		tour_i += 1
		tour_placed = false
		step_t = 0.0

func _process(dt: float) -> void:
	t += dt
	step_t += dt
	if main == null:
		main = get_tree().current_scene as DmMain
		if main == null:
			return
		main.hero.qa_input_disabled = true
		main.spawning_enabled = false
		step_t = 0.0
		return
	var hero := main.hero
	if tour:
		_tour(dt)
		return
	match step:
		0:  # settle, then the Chapterhouse at spawn
			if step_t > 2.0:
				_shot("01_chapterhouse_spawn")
				step = 1
				step_t = 0.0
		1:  # walk north through the door with real click-to-move
			if step_t < 0.1 or fmod(step_t, 3.0) < dt:
				hero.move_to(Vector3(0, 0, -6))
			if hero.global_position.z < 1.0 or step_t > 15.0:
				print("[qa] reached graves z=", hero.global_position.z, " after ", step_t)
				main.spawning_enabled = true
				main.spawn_timer = 1000.0
				step = 2
				step_t = 0.0
		2:  # a wave; fight
			if not _spawned:
				_spawned = true
				main.spawn_wave(9)
				print("[qa] wave spawned: ", get_tree().get_nodes_in_group("enemies").size())
			var foe := main.nearest_enemy_to_hero(40.0)
			if foe != null:
				if foe.global_position.distance_to(hero.global_position) < 9.0:
					hero.fire_at(foe.global_position)
				elif int(step_t * 2.0) % 6 == 0:
					pass
			# thrall raising once there are corpses (QA also thins enemies near the hero so corpses appear quickly)
			if step_t > 3.0 and fmod(step_t, 1.2) < dt:
				var near := main.enemy_near(hero.global_position, 7.0)
				if near != null and get_tree().get_nodes_in_group("corpses").size() < 3:
					near.take_damage(near.hp + 1.0)
			var corpses := get_tree().get_nodes_in_group("corpses")
			if corpses.size() > 0 and get_tree().get_nodes_in_group("thralls").size() < 3 and fmod(step_t, 0.7) < dt:
				hero.essence = hero.max_essence
				hero._exhume_cd = 0.0
				hero.do_exhume(corpses[0].global_position)
			if get_tree().get_nodes_in_group("thralls").size() >= 2 and step_t > 9.0:
				step = 3
				step_t = 0.0
			elif step_t > 40.0:
				step = 3
				step_t = 0.0
		3:  # let the fight run, then mid-fight shot with F3 on
			var foe2 := main.nearest_enemy_to_hero(40.0)
			if foe2 != null and foe2.global_position.distance_to(hero.global_position) < 9.0:
				hero.fire_at(foe2.global_position)
			if step_t > 3.0 and step_t - dt <= 3.0:
				_shot("02_graves_fight")
			if step_t > 3.5 and not main.perf.panel.visible:
				main.perf.set_shown(true)
			if step_t > 7.0:
				_shot("03_graves_fight_f3")
				var s := main.perf.summary()
				print("[qa] perf ", s)
				print("[qa] kills=", main.kills, " thralls=", get_tree().get_nodes_in_group("thralls").size(), " enemies=", get_tree().get_nodes_in_group("enemies").size(), " corpses=", get_tree().get_nodes_in_group("corpses").size())
				step = 4
				step_t = 0.0
		4:
			print("[qa] done")
			get_tree().quit()
