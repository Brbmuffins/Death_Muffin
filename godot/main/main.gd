class_name DmMain
extends Node3D
## Slice root: builds the world from exported data, the hero + camera, the Graves wave spawner, the HUD and the F3 overlay.

const MAX_CORPSES := 60

var world: Dictionary
var enemies_data: Dictionary
var hero_data: Dictionary
var builder: DmWorldBuilder
var hero: DmHero
var cam: DmCameraRig
var hud: DmSliceHud
var perf: DmPerfOverlay
var audio_hooks: DmAudioHooks
var settings_menu: DmSettingsMenu
var area_id := "chapterhouse"
var spawn_timer := 2.0
var spawning_enabled := true
var kills := 0
var thrall_serial := 0
var log_lines: Array[String] = []

func _ready() -> void:
	world = DmData.world()
	enemies_data = DmData.enemies()
	hero_data = DmData.hero()
	builder = DmWorldBuilder.new()
	builder.name = "World"
	add_child(builder)
	builder.build(world)
	cam = DmCameraRig.new()
	cam.name = "Camera"
	add_child(cam)
	cam.setup(world.camera)
	hero = DmHero.new()
	hero.name = "Hero"
	add_child(hero)
	hero.setup(hero_data, self, cam)
	var sp: Dictionary = world.spawn.chapterhouseReturn
	hero.global_position = Vector3(sp.x, 0, sp.z)
	cam.snap(hero.global_position)
	hud = DmSliceHud.new()
	add_child(hud)
	hud.setup(self)
	perf = DmPerfOverlay.new()
	add_child(perf)
	audio_hooks = DmAudioHooks.new()
	add_child(audio_hooks)
	audio_hooks.setup(self)
	settings_menu = DmSettingsMenu.new()
	add_child(settings_menu)
	settings_menu.setup()
	if "--open-all" in OS.get_cmdline_user_args():
		builder.open_all()
	_update_area()

func _unhandled_key_input(ev: InputEvent) -> void:
	# Dev: F9 breaks every seal (the web's __cwDebug.unlockAll). Real seal state comes from the progression/sim track via builder.set_unlocked().
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.physical_keycode == KEY_F9:
		builder.open_all()
		hud.note("all seals broken (dev)")

func _process(dt: float) -> void:
	cam.update_rig(dt, hero.global_position)
	_update_area()
	builder.update_streaming(cam.focus.x, cam.focus.z)
	builder.update_light_lod(cam.focus.x, cam.focus.z)
	var a: Dictionary = world.areas[area_id]
	if spawning_enabled and not a.safe and not a.instance and float(a.waveSize) > 0.0:
		spawn_timer -= dt
		if spawn_timer <= 0.0:
			spawn_timer = float(a.waveIntervalMs) / 1000.0
			var alive := get_tree().get_nodes_in_group("enemies").size()
			var n := mini(int(a.waveSize), int(a.cap) - alive)
			if n > 0:
				spawn_wave(n)

func _update_area() -> void:
	var id := builder.area_at(hero.global_position.x, hero.global_position.z)
	if id == "":
		id = area_id  # in a door corridor: keep the room you came from
	if id != area_id:
		area_id = id
		builder.set_area(id)
		hud.on_area(world.areas[id])
		spawn_timer = 1.0
	elif hud != null and hud.area_label.text == "":
		hud.on_area(world.areas[id])

# --------------------------------------------------------------- spawning
func _pick_enemy_id() -> String:
	var roster: Array = world.areas[area_id].enemies
	var total := 0.0
	for r in roster:
		total += float(r.weight)
	var x := randf() * total
	for r in roster:
		x -= float(r.weight)
		if x <= 0.0:
			return r.id
	return roster[0].id

func spawn_wave(n: int) -> void:
	var g: Dictionary = world.areas[area_id]
	var rect: Dictionary = g.rect
	var spots: Array = []
	for b in g.breaches:
		var d := Vector2(b[0] - hero.global_position.x, b[1] - hero.global_position.z).length()
		if d >= 9.0 and d <= 30.0:
			spots.append(Vector3(b[0], 0, b[1]))
	for i in n:
		var p: Vector3
		if spots.is_empty():
			p = Vector3(randf_range(rect.x0 + 2, rect.x1 - 2), 0, randf_range(rect.z0 + 2, rect.z1 - 8))
		else:
			p = spots[randi() % spots.size()] + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5))
		spawn_enemy(_pick_enemy_id(), p)

func spawn_enemy(id: String, p: Vector3) -> DmEnemy:
	var d: Dictionary = enemies_data.defs[id]
	var e := DmEnemy.new()
	add_child(e)
	e.global_position = Vector3(p.x, 0, p.z)
	var model: Dictionary = _enemy_model(d)
	e.setup(d, self, model)
	return e

var _model_cache: Dictionary = {}
func _enemy_model(d: Dictionary) -> Dictionary:
	if not _model_cache.has(d.model):
		_model_cache[d.model] = enemies_data.models[d.model]
	return _model_cache[d.model]

# --------------------------------------------------------------- targeting / corpses / thralls
func world_nav_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	return builder.nav_path(from, to)

func pick_target(from: Vector3) -> Node3D:
	var best: Node3D = hero
	var bd := from.distance_to(hero.global_position) * 0.8  # the hero draws aggression a little
	for t in get_tree().get_nodes_in_group("thralls"):
		if not t.alive:
			continue
		var d := from.distance_to(t.global_position)
		if d < bd:
			bd = d
			best = t
	return best

func enemy_near(p: Vector3, r: float) -> DmEnemy:
	var best: DmEnemy = null
	var bd := r
	for e in get_tree().get_nodes_in_group("enemies"):
		if not e.alive:
			continue
		var d := Vector2(e.global_position.x - p.x, e.global_position.z - p.z).length()
		if d < bd:
			bd = d
			best = e
	return best

func nearest_enemy_to_hero(maxd: float) -> DmEnemy:
	return enemy_near_from(hero.global_position, maxd)

func enemy_near_from(p: Vector3, maxd: float) -> DmEnemy:
	return enemy_near(p, maxd)

func corpse_near(at: Vector3, radius: float, from: Vector3, reach: float) -> Node3D:
	var best: Node3D = null
	var bd := radius
	for c in get_tree().get_nodes_in_group("corpses"):
		if c.corpse_kind == "none":
			continue
		if c.global_position.distance_to(from) > reach:
			continue
		var d := Vector2(c.global_position.x - at.x, c.global_position.z - at.z).length()
		if d < bd:
			bd = d
			best = c
	return best

func on_enemy_killed(e: DmEnemy) -> void:
	kills += 1
	hero.kills = kills
	var g: Dictionary = world.areas[area_id]
	hud.note("+%d xp   %s" % [int(e.def.xp), e.def.name])
	if not g.loot.is_empty() and randf() < float(g.itemChance) * 104.0 / 134.0:
		var total := 0.0
		for l in g.loot:
			total += float(l.weight)
		var x := randf() * total
		for l in g.loot:
			x -= float(l.weight)
			if x <= 0.0:
				DmAudioHooks.loot_drop(str(l.get("rarity", "common")), e.global_position)
				DmFx.float_text(self, e.global_position + Vector3(0, 1.4, 0), "[%s]" % l.name, Color(1.0, 0.8, 0.3), 36, 1.0, 2.0)
				hud.note("Loot: %s" % l.name)
				break
	var corpses := get_tree().get_nodes_in_group("corpses")
	if corpses.size() > MAX_CORPSES:
		corpses[0].queue_free()

func raise_thrall(corpse: Node3D) -> void:
	var th: Array = get_tree().get_nodes_in_group("thralls")
	var cap := int(hero_data.discipline.thrallCap)
	if th.size() >= cap:
		(th[0] as DmThrall).crumble()  # at the cap the oldest thrall crumbles
	var p: Vector3 = corpse.global_position
	corpse.remove_from_group("corpses")
	corpse.queue_free()
	var t := DmThrall.new()
	add_child(t)
	t.global_position = p
	t.setup(hero_data.thrall, self, hero, hero_data.thrall_model, thrall_serial % cap)
	DmAudioHooks.thrall_raised(p)
	thrall_serial += 1
	DmFx.float_text(self, p + Vector3(0, 2.0, 0), "Thrall", Color(0.7, 0.9, 1.0), 34)

func on_thrall_gone(_t: DmThrall) -> void:
	pass

# --------------------------------------------------------------- misc
func screenshot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
