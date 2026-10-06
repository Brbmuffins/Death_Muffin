extends SceneTree
## Slice shell suite (godot/next). godot --headless --path godot --script res://tests/next/run.gd
## Boots DmNextGame solo through DmSession (OfflineMultiplayerPeer), then drives it in physics ticks with Engine.time_scale raised.
## Part B runs a second DmNextGame as a client over ENet (127.0.0.1:5203) to prove spawn + state replication on the same code path.

const DT := 1.0 / 60.0
var PORT := DmTestPorts.free_port()   # random free port per run (parallel suites)

class ErrLog extends Logger:
	var errors: Array = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, _bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s" % [file.get_file(), line, code, rationale])

var passed := 0
var failed := 0
var log_ := ErrLog.new()
var g: DmNextGame
var api: DmApi
var character: Dictionary


func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)

func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame

func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()

func _new_game(opts: Dictionary) -> DmNextGame:
	var n: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(n)
	await n.start(character, api, opts)
	return n


func _run() -> void:
	OS.add_logger(log_)
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("shell%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	character = c.data
	await _part_a()
	await _part_b()
	check(log_.errors.is_empty(), "no engine errors in the log (%d: %s)" % [log_.errors.size(), ", ".join(log_.errors.slice(0, 3))])
	OS.remove_logger(log_)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _part_a() -> void:
	# ---- boot solo through the session
	var t0 := Time.get_ticks_msec()
	g = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	var spawned: Array = []
	g.enemy_spawned.connect(func(e: DmEnemy) -> void: spawned.append(e))
	await g.start(character, api, {"dressing": false, "hud": "minimal"})
	var boot_ms := Time.get_ticks_msec() - t0
	print("boot: %d ms (world build %d ms incl. navmesh bake %d ms + first nav sync %d ms)" % [boot_ms, g.world.build_ms, g.world.bake_ms, g.world.sync_ms])
	check(g.session.is_active() and g.session.is_host(), "A: boots as a hosting session")
	check(g.session.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "A: solo = OfflineMultiplayerPeer, no sockets")
	check(g.session.get_roster().size() == 1 and g.local_body() != null, "A: roster of 1, local body exists")
	var hb := g.local_body()
	check(hb is DmHeroBody and hb.is_in_group(DmEnemy.TARGET_GROUP) and hb.dm_alive(), "A: body is a DmHeroBody in group dm_target")
	await ticks(2)
	check(hb.avatar != null and hb.avatar.c != null, "A: hero has the DmAvatar model")
	check(hb.avatar.slug == String(DmContent.discipline(hb.discipline_id)["modelSlug"]), "A: avatar model matches the discipline")
	check(hb.max_hp > 0.0 and hb.hp == hb.max_hp and hb.take_damage(1.0, null) >= 0.0, "A: hp + take_damage(amount, source)")
	check(g.area_id == "chapterhouse", "A: starts in the Chapterhouse (%s)" % g.area_id)
	# ---- world + navmesh
	check(g.world.builder != null and g.world.builder.area_nodes.has("graves") and g.world.builder.area_nodes.has("chapterhouse"), "A: Chapterhouse + Hollow Graves built")
	check(g.world.builder.nav_regions.has("area:graves") and g.world.builder.nav_regions.has("area:chapterhouse") and g.world.builder.nav_regions.has("door:chapter_graves"), "A: navmesh regions for both areas + the door")
	check(g.world.nav_ready(), "A: navigation map synced")
	var nm: NavigationMesh = (g.world.builder.nav_regions["area:graves"] as NavigationRegion3D).navigation_mesh
	check(nm.get_polygon_count() > 50, "A: Graves navmesh has polygons (%d)" % nm.get_polygon_count())
	var gpath := g.world.nav_path(Vector3(0, 0, 24), Vector3(0, 0, -10))
	check(gpath.size() >= 2 and gpath[gpath.size() - 1].distance_to(Vector3(0, 0, -10)) < 1.5, "A: nav path Chapterhouse -> Graves (%d points)" % gpath.size())
	check(g.hud.hp_orb != null and g.hud.res_orb != null and g.hud.area_label != null, "A: HUD orbs + area label exist")
	check(g.world.builder.env.fog_enabled and g.world.builder.moon != null, "A: world lighting + fog present")
	# ---- click to move along the navmesh
	Engine.time_scale = 4.0
	var target := Vector3(0.0, 0.0, -6.0)
	g.input.click_move(target)
	var off_mesh := 0.0
	var moved := await until(func() -> bool:
		var q := g.world.nav_closest(hb.position)
		off_mesh = maxf(off_mesh, Vector2(q.x - hb.position.x, q.z - hb.position.z).length())
		return Vector2(hb.position.x - target.x, hb.position.z - target.z).length() < 0.3, 15.0)
	check(moved, "A: click-to-move reaches the clicked point (at %s)" % hb.position)
	check(off_mesh < 0.1, "A: the walk stays on the navmesh (max off-mesh %.3f m)" % off_mesh)
	check(g.area_id == "graves", "A: area switches to the Hollow Graves (%s)" % g.area_id)
	# WASD / direction intent
	var p0 := hb.position
	g.session.request_move_dir(Vector3(1, 0, 0))
	await ticks(20)
	g.session.request_move_dir(Vector3.ZERO)
	check(hb.position.x > p0.x + 0.5, "A: direction intent moves the hero")
	check(InputMap.has_action(&"dm_hotbar_1") and InputMap.has_action(&"dm_primary") and InputMap.has_action(&"dm_secondary") and InputMap.has_action(&"dm_move_up"), "A: input actions registered")
	# ---- waves, chase, hits
	hb.teleport(Vector3(0, 0, -16))
	check(await until(func() -> bool: return g.director.alive_count() >= 3, 10.0), "A: robbers spawn in the Graves")
	check(not spawned.is_empty() and ResourceLoader.exists("res://enemies/%s.tscn" % spawned[0].def_id), "A: enemy_spawned fires for kinds that have a scene")
	check(spawned[0].get_meta(&"dm_area") == "graves" and spawned[0].get_meta(&"dm_level") >= 1.0 and spawned[0].has_meta(&"dm_elite"), "A: enemies carry dm_level / dm_elite / dm_area metas")
	var e0: DmEnemy = spawned[0]
	check(e0.is_multiplayer_authority() and e0.hp_mult >= 1.0 and DmWaveDirector.id_of(e0) > 0, "A: enemy hooks set (authority, hp_mult, id)")
	check(await until(func() -> bool: return spawned.any(func(e: DmEnemy) -> bool: return e.sm.id() == DmEnemyState.Id.CHASE or e.sm.id() == DmEnemyState.Id.ATTACK), 10.0), "A: robbers chase")
	hb.heal(1e6)
	var hp_before := hb.hp
	check(await until(func() -> bool: return hb.hp < hp_before - 5.0, 20.0), "A: robbers hit the player (hp %.0f -> %.0f)" % [hp_before, hb.hp])
	check(g.director.waves_spawned >= 1 and g.director.alive_count() <= g.director.cap, "A: wave pacing + cap")
	# ---- seams
	# The kill / needle checks below need enemies that can be hurt: a rising one and a burrowed ghoul are immune (which kind spawns is random).
	var hurtable := func(e: DmEnemy) -> bool: return is_instance_valid(e) and e.sm.id() != DmEnemyState.Id.DEAD and e.sm.id() != DmEnemyState.Id.RISING and e.is_hittable()
	check(await until(func() -> bool: return spawned.any(hurtable), 15.0), "A: a hurtable enemy is up")
	e0 = spawned.filter(hurtable)[0]
	var near := g.enemies_in_radius(e0.global_position, 1.0)
	check(near.has(e0) and g.enemy_by_id(DmWaveDirector.id_of(e0)) == e0 and g.enemy_by_id(99999) == null, "A: seam enemies_in_radius / enemy_by_id")
	check(g.enemies_in_radius(Vector3(500, 0, 500), 5.0).is_empty(), "A: enemies_in_radius far away is empty")
	var ro := g.roster()
	check(ro.size() == 1 and ro[0]["peer_id"] == 1 and ro[0]["character_id"] == int(character["id"]) and ro[0]["discipline"] == hb.discipline_id and ro[0]["body"] == hb, "A: seam roster (peer, discipline, character id, body)")
	check(g.body_position(1) == hb.position and g.area_of(1) == g.area_id, "A: seam body_position / area_of")
	check(g.api == api and g.is_offline, "A: seam api + offline flag")
	var caster := hb.get_node_or_null("Rites") as DmRiteCaster
	check(caster != null and caster.world == g, "A: a DmRiteCaster named Rites is attached to the player body")
	check(g.enemy_id(e0) == DmWaveDirector.id_of(e0) and g.rite_build(1).has("stats") and g.aim_point() is Vector3, "A: DmRiteWorld hooks (enemy_id, rite_build, aim_point)")
	check(g.rewards is DmSessionRewards, "A: rewards node is the real DmSessionRewards")
	var kills := [0]
	g.rewards.kill_earned.connect(func(_c: int, _d: String, _p: Vector3) -> void: kills[0] += 1)
	var en := g.enemies_in_radius(hb.position, 8.0).filter(hurtable)
	if en.is_empty():   # none of them in reach right now: bring the hurtable one to the hero
		hb.teleport(e0.global_position + Vector3(0, 0, 3))
		en = [e0]
	en.sort_custom(func(a: DmEnemy, b: DmEnemy) -> bool: return a.global_position.distance_to(hb.position) < b.global_position.distance_to(hb.position))
	var ne: DmEnemy = en[0]
	var ehp := ne.hp
	caster.request_cast("bone_needle", ne.global_position, DmWaveDirector.id_of(ne))
	check(await until(func() -> bool: return ne.hp < ehp or ne.sm.id() == DmEnemyState.Id.DEAD, 3.0), "A: the rite caster's needle hits an enemy")
	e0.take_damage(1e9, hb)
	await ticks(3)
	# exact: 1 for e0, +1 when the needle above killed `ne` (a kill credited twice would read one more)
	var want_kills := 1 + (1 if (ne != e0 and is_instance_valid(ne) and ne.sm.id() == DmEnemyState.Id.DEAD) else 0)
	check(e0.sm.id() == DmEnemyState.Id.DEAD and kills[0] == want_kills, "A: rewards seam credits each kill once (%d, want %d)" % [kills[0], want_kills])
	check(e0.get_node_or_null("Statuses") is DmStatusSet, "A: spawned enemies carry a replicated DmStatusSet")
	check(hb.get_node_or_null("Thralls") is DmThrallHost and hb.get_node_or_null("Statuses") is DmStatusSet and hb.get_node_or_null("Rites") != null, "A: the hero carries Rites, Thralls and Statuses")
	var want_corpse: bool = e0.corpse_kind != "none"
	check(g.corpses != null and (g.corpses.count() > 0) == want_corpse, "A: a killed %s leaves a corpse: %s (corpses %d)" % [e0.def_id, want_corpse, g.corpses.count()])
	# ---- death -> respawn in the Chapterhouse
	var died_seen := [0]
	var resp_seen := [0]
	g.hero_died.connect(func(_b: DmHeroBody) -> void: died_seen[0] += 1)
	g.hero_respawned.connect(func(_b: DmHeroBody) -> void: resp_seen[0] += 1)
	hb.take_damage(1e6, e0)
	check(not hb.alive and not hb.dm_alive() and died_seen[0] == 1, "A: hero dies")
	check(await until(func() -> bool: return hb.alive, DmHeroBody.RESPAWN_S + 2.0), "A: hero respawns")
	var ret: Dictionary = DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")
	check(Vector2(hb.position.x - float(ret["x"]), hb.position.z - float(ret["z"])).length() < 0.6 and hb.hp == hb.max_hp and resp_seen[0] == 1, "A: respawn in the Chapterhouse at full hp (%s)" % hb.position)
	await ticks(3)
	check(g.area_id == "chapterhouse", "A: area back to the Chapterhouse")
	g.hud.refresh()
	check(g.hud.area_label.text == "THE CHAPTERHOUSE" and is_equal_approx(g.hud.hp_orb.fill, 1.0) and not g.hud.death_veil.visible, "A: HUD shows area name, full orb, no death veil")
	# ---- perf: 25 chasing enemies, headless tick cost
	Engine.time_scale = 1.0
	hb.teleport(Vector3(0, 0, -16))
	g.director.enabled = false
	g.director.clear()
	await ticks(5)
	var heroes := [hb]
	for i in 25:
		g.director.spawn("robber", Vector3(sin(i * 0.5) * 11.0, 0.0, -16.0 + cos(i * 0.5) * 11.0), heroes)
	await ticks(150)
	check(g.director.alive_count() == 25, "A: 25 robbers alive (%d)" % g.director.alive_count())
	hb.heal(1e6)
	# DmFrameCost: wall time of whole frames (physics + process + redraw), lifted frame limiter. The engine's TIME_PROCESS / TIME_PHYSICS_PROCESS
	# monitors are windowed maxima (one stall is held for ~1 s), so their mean flaked on a shared VPS. Median budget + generous worst-frame cap.
	var fc := DmFrameCost.attach(root)
	await ticks(5)
	fc.reset()   # warm-up excluded
	var n := 180
	for i in n:
		await physics_frame
		hb.heal(1e6)
	fc.queue_free()
	print("perf: 25 robbers chasing, headless: frame median %.2f ms (p95 %.2f, worst %.2f, %d samples)" % [fc.median_ms(), fc.p95_ms(), fc.worst_ms(), fc.samples()])
	check(fc.median_ms() < 14.0 and fc.worst_busy_ms() < 150.0, "A: 25 chasing enemies: frame median %.2f ms under 14, worst %.1f ms under 150" % [fc.median_ms(), fc.worst_ms()])
	g.queue_free()
	await ticks(3)


func _part_b() -> void:
	# A host and a client DmNextGame, each in its own SceneMultiplayer branch, over ENet loopback.
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	var hg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	var cg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(PORT, 4) == OK, "B: ENet server created")
	await hg.start(character, api, {"peer": sp, "dressing": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", PORT)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "hud": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "B: client joined, 2 hero bodies on both")
	check(cg.local_body() is DmHeroBody and cg.local_body().owner_peer == cg.session.get_my_id(), "B: client has its own DmHeroBody")
	var hh := hg.local_body()
	hh.teleport(Vector3(0, 0, -16))
	check(await until(func() -> bool: return hg.director.alive_count() >= 3 and cg.director.enemies.size() >= 3, 12.0), "B: enemies spawned on the host replicate to the client")
	# One check over however many enemies the wave has spawned by now (a check per enemy made the suite's check count vary run to run).
	var all_puppets := true
	for id in cg.director.enemies:
		var ce: DmEnemy = cg.director.enemies[id]
		all_puppets = all_puppets and (not ce.is_multiplayer_authority() or cg.session.multiplayer.is_server())
	check(all_puppets, "B: every client enemy is a puppet")
	# Replicated state is eventually consistent: poll for the condition (a one-instant sample races the enemies' movement and the host's send rate).
	var matched := [0]
	await until(func() -> bool:
		matched[0] = 0
		for id in cg.director.enemies:
			var he: DmEnemy = hg.director.enemy_by_id(id)
			var ce2: DmEnemy = cg.director.enemies[id]
			if he != null and he.global_position.distance_to(ce2.global_position) < 1.5:
				matched[0] += 1
		return matched[0] >= 3 and cg.net.states_applied > 0, 10.0)
	check(matched[0] >= 3 and cg.net.states_applied > 0, "B: client enemy positions follow the host (%d matched, %d states)" % [matched[0], cg.net.states_applied])
	hh.take_damage(10.0, null)
	check(await until(func() -> bool:
		var b1 := cg.body_of(1)
		return b1 != null and absf(b1.hp - hh.hp) < 1.0, 5.0), "B: host hero vitals reach the client")
	var ch := cg.local_body()
	cg.session.request_move_to(Vector3(0, 0, -20))

	check(await until(func() -> bool: return hg.body_of(ch.owner_peer).position.distance_to(Vector3(0, 0, -20)) < 1.0, 25.0), "B: client move intent walks its host-side body (at %s)" % hg.body_of(ch.owner_peer).position)
	hg.queue_free()
	cg.queue_free()
	await ticks(5)
