extends SceneTree
## Rendered check of the view layer: godot --rendering-driver opengl3 --path godot --script res://tests/game/views_shot.gd -- --out=shots/game/views.png
## (run under the renderer lock: flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock nice -n 10 xvfb-run -a ...). Enemies, thralls, the hero avatar and a boss.

var out_path := "res://shots/game/views.png"
var cam_args: PackedFloat64Array = PackedFloat64Array([0, 8.5, 11.5, 0, 0.8, -1.5])

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.substr(6)
		elif a.begins_with("--cam="):
			cam_args = PackedFloat64Array(Array(a.substr(6).split(",")).map(func(x): return float(x)))
	_run.call_deferred()

func _enemy(id: int, def: String, x: float, z: float, elite := false, affix := "") -> DmSimEnemy:
	var d := DmContent.enemy(def)
	var e := DmSimEnemy.new()
	e.id = id
	e.def = def
	e.area = "graves"
	e.x = x
	e.z = z
	e.facing = PI
	e.hp = float(d.hp)
	e.maxHp = float(d.hp)
	e.scale = float(d.scale) * (1.35 if elite else 1.0)
	e.radius = float(d.radius)
	e.speed = float(d.speed)
	e.state = "move"
	e.stateT = 5.0
	e.elite = elite
	e.affix = affix
	return e

func _thrall(id: int, kind: String, x: float, z: float) -> DmSimThrall:
	var t := DmSimThrall.new()
	t.id = id
	t.owner = "p1"
	t.kind = kind
	t.x = x
	t.z = z
	t.facing = 0.0
	t.state = "idle"
	t.stateT = 5.0
	t.speed = 5.0
	return t

func _run() -> void:
	var T = load("res://tests/game/test_views.gd")
	var host: Node3D = T.StubHost.new()
	host.world_root = host
	root.add_child(host)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.04, 0.07)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.5, 0.65)
	e.ambient_light_energy = 0.7
	e.glow_enabled = true
	env.environment = e
	host.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	host.add_child(sun)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.16, 0.15, 0.17)
	floor_mi.material_override = fm
	host.add_child(floor_mi)
	var cam := Camera3D.new()
	cam.position = Vector3(cam_args[0], cam_args[1], cam_args[2])
	cam.look_at_from_position(cam.position, Vector3(cam_args[3], cam_args[4], cam_args[5]), Vector3.UP)
	cam.fov = 48.0
	cam.current = true
	host.add_child(cam)

	var views := DmEntityViews.new()
	views.setup(host)
	host.kit = {"weapon": {"itemId": "staff_gold", "rarity": "epic"}, "armor": {"itemId": "set_knight_chest", "rarity": "epic"}}
	var enemies := {}
	var thralls := {}
	var defs := [["robber", false, ""], ["hound", false, ""], ["deacon", false, ""], ["wraith", false, ""], ["gargoyle", false, ""], ["moth", false, ""],
		["bat", false, ""], ["robber", true, "shrouded"], ["cinder_husk", false, ""], ["slag_brute", false, ""], ["risen", false, ""], ["censer", false, ""], ["acolyte", false, ""]]
	var i := 0
	for d in defs:
		var x := -9.0 + float(i % 7) * 3.0
		var z := -5.5 if i < 7 else -9.5
		enemies[100 + i] = _enemy(100 + i, d[0], x + (1.5 if i >= 7 else 0.0), z, d[1], d[2])
		i += 1
	var kinds := ["warrior", "shieldbearer", "archer", "bonemage", "wraith", "plaguebearer", "hound", "colossus"]
	i = 0
	for k in kinds:
		thralls[200 + i] = _thrall(200 + i, k, -7.0 + float(i) * 2.2, 2.4)
		i += 1
	# the hero, a boss
	var av := DmAvatar.new()
	av.settings = {"hideHelm": false}
	av.setup(host, "#a26bff", false, "hero_ossuary")
	av.set_equipment({"main_hand": {"item_id": "staff_gold"}, "head": {"item_id": "set_gravecaller_head"}, "chest": {"item_id": "set_gravecaller_chest"}, "hands": {"item_id": "set_gravecaller_hands"}})
	var av2 := DmAvatar.new()
	av2.setup(host, "#e0a458", false, "hero_hollow_knight")
	av2.set_equipment({"chest": {"item_id": "armor_iron_chest"}, "main_hand": {"item_id": "sword_steel"}, "off_hand": {"item_id": "shield_iron"}})
	var bv := DmBossView.new()
	bv.setup(host, "gravedigger")
	var bs := DmBossState.new()
	bs.id = "gravedigger"
	bs.active = true
	bs.x = 8.5
	bs.z = -1.0
	bs.facing = -0.8
	bs.hp = 1000.0
	bs.maxHp = 1000.0
	bs.state = "idle"
	for f in 90:
		await process_frame
		var dt := 1.0 / 30.0
		for id in enemies:
			var en: DmSimEnemy = enemies[id]
			en.moving = (id % 3 == 0)
			if en.moving:
				en.x += 0.0
		for id in thralls:
			(thralls[id] as DmSimThrall).moving = (id % 2 == 0)
		views.sync(enemies, thralls, dt, 0.0, 0.0)
		av.update(dt, -2.0, 6.0, 0.4, false, 5.0)
		av2.update(dt, 2.0, 6.0, -0.4, false, 5.0)
		bv.sync(bs, dt)
		if f == 20:
			av.cast("cast", 1.0, null, 0.8, "exhume")
		if f == 40:
			views.on_event({"t": "thrall", "x": 0.0, "z": 0.0})
	# two bodies fall
	for id in [100, 102]:
		views.on_event({"t": "death", "id": id, "def": enemies[id].def, "x": enemies[id].x, "z": enemies[id].z, "elite": false})
		enemies.erase(id)
	for f in 60:
		await process_frame
		views.sync(enemies, thralls, 1.0 / 30.0, 0.0, 0.0)
		av.update(1.0 / 30.0, -2.0, 6.0, 0.4, false, 5.0)
		bv.sync(bs, 1.0 / 30.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var abs_path := out_path if out_path.begins_with("/") else ProjectSettings.globalize_path("res://").path_join(out_path.trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var img := root.get_texture().get_image()
	img.save_png(abs_path)
	print("saved ", abs_path, " ", img.get_size(), " ", views.counts())
	quit()
