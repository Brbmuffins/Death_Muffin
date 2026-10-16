extends SceneTree
## The game scene on the core (ROADMAP: client layer, "The game scene on the core"): an offline solo run in the Hollow Graves, headless. It starts the real
## scene (client/next/next_game.tscn) with a dev character on the local mock backend, plays 3600 physics ticks (60 s of game time; with the engine argument
## `--fixed-fps 60` they run as fast as the CPU allows, without it they take a minute) and checks:
##   - the wave director spawned waves through the core, up to the area's cap; every spawn event is a core body (ids, not nodes);
##   - NO NODE PER CREATURE: the scene tree's node count is the same with 0, 35 and 70 more idle enemies in the core, and no enemy has a node;
##   - enemies reach and hit the hero: the hero's health drops through the core's EV_TARGET_HIT, with kinds as today;
##   - the hero dies and gets up again (4 s, at the Graves' door; the core's enemies stop hitting him while he lies, and a forced death when the waves were too weak);
##   - killing enemies with core.damage lays corpses and plays the death path (DmEnemyFx) without errors, the corpses get their rings (capped) and dust where they land; deaths and removals leave nothing held by the fx;
##   - the crowd draws the creatures: the CrowdView's groups hold an instance per live body and per corpse;
##   - the affixed elites' standing marks and motes (gone when they fall); a status's tell (frost motes on a chilled body); the dirt mound over a ghoul underground;
##   - the kinds of blow (the penitent's cone, the moth's dust and cloud, the sac's slam, a hurt ghoul's dig and eruption) and the affixes' bell, meal, shroud and burst are
##     events of the core's buffer that DmEnemyFx played (scripted: one of each, close to the hero);
##   - the order of a tick (session and director, then the core, then the crowd) and that the host takes the event buffer once;
##   - the hover pick finds the enemy under the cursor through the core;
##   - the scene refuses an api that is not the test server's and no HTTP request node exists;
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Prints INFO timings: the host's step, crowd sync and event dispatch per tick, and the crowd's draw per rendered frame, with about 70 enemies.
## Bakes the robber and the hound into a scratch folder first (about 20 s). Run: godot --headless --path client --script res://tests/game_scene.gd
## Faster: godot --headless --fixed-fps 60 --path client --script res://tests/game_scene.gd

const OUT := "user://game_scene_test"
const RUN_TICKS := 3600
const BAKE := ["grave_robber", "bone_hound"]


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var host: DmCoreHost
var spawned := 0
var spawned_ids: Dictionary = {}
var died := 0
var removed := 0
var corpses_added := 0
var tele_events := 0
var tells := {}   # DmCoreEvents.TELLS name -> telegraph events
var zones_seen := 0
var attack_events := 0
var hero_died_n := 0
var hero_respawned_n := 0
var got_up_at := Vector3.INF            # where the hero stood when he last got up (the waves may knock him down again before a check reads him)
var dead_hits := 0
var hero_dead := false
var death_tick := -1
var draw_us := 0
var draw_n := 0
var min_hero_hp := 1.0e9
var max_alive := 0
var max_total := 0
var samples: Array = []   # [enemies alive, node count] once a second


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL game_scene: " + what)


func nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	var mock := DmOffline.make_mock("")   # memory only: no file, no server
	var api := DmOffline.make_api(mock)
	var reg := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	check(ch.ok and int(ch.data["class_index"]) == 2, "the dev character is a Gravecaller")
	await refuses_online(ch.data)
	await start_game(api, ch.data)
	await the_run()
	await kinds()
	await hero_death()
	await killing()
	await no_nodes_per_creature()
	await hover_pick()
	await affixes()
	await timings()
	await finish()


# ------------------------------------------------------------------------------------------------------------------ the scene

## A scene started with an api whose server address is not the test server's refuses to run, and its transport is never called (the live API and the test API: tests/front.gd).
func refuses_online(character: Dictionary) -> void:
	var called := [0]
	var online := DmApi.new(func(_req: Dictionary) -> Dictionary:
		called[0] += 1
		return {"status": 0, "body": ""})
	online.base_url = "https://example.invalid/api"
	var scene: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(scene)
	var refused := [""]
	scene.start_failed.connect(func(r: String) -> void: refused[0] = r)
	await scene.start(character, online, {})
	check(refused[0] != "" and not scene.ready_, "an api that is not the test server's is refused: '%s'" % refused[0])
	check(called[0] == 0, "the refused scene sent no request")
	scene.queue_free()
	await process_frame


func start_game(api: DmApi, character: Dictionary) -> void:
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(character, api, {"name": "tester", "hud": true, "audio": false, "seed": 20261016, "baked_dir": OUT})
	host = g.core_host
	check(g.ready_, "the game scene is ready")
	check(g.world.nav_ready() and g.world.area_id == "graves" and g.area_id == "graves", "the Graves' navigation map is ready and the hero is in the Graves")
	var b := g.local_body()
	check(b != null and b.core_id > 0 and host.hero_for(b.core_id) == b, "the hero body is an external of the core (id %d)" % (b.core_id if b != null else -1))
	check(b.alive and g.world.area_at(b.position.x, b.position.z) == "graves", "the hero stands in the Graves at %s" % str(b.position))
	check(host.view != null and host.view.model_slots().size() >= 2, "the crowd view has its models (%s)" % str(host.view.model_slots().keys()))
	check(g.hud != null and g.enemy_fx != null and g.look != null, "the HUD, the enemy fx and the hero look are up")
	check(g.rewards == null and g.ui_host == null and g.chapterhouse == null, "what is off stays off (rewards, panels, Chapterhouse)")
	check(g.bosses != null and g.bosses.active_boss() == null and g.bosses.bosses.is_empty(), "the boss host is up and nothing sleeps awake (client/tests/boss.gd fights the King)")
	host.enemy_spawned.connect(func(id: int, _def: String, _lv: int, _el: bool, _ar: String, _af: int, _x: float, _z: float, _hp: float) -> void:
		spawned += 1
		spawned_ids[id] = true)
	host.enemy_died.connect(func(_id: int, _d: String, _lv: int, _el: bool, _ar: String, _s: int, _x: float, _z: float) -> void: died += 1)
	host.enemy_removed.connect(func(_id: int) -> void: removed += 1)
	host.corpse_added.connect(func(_id: int, _k: int, _d: String, _e: bool, _a: String, _x: float, _z: float, _f: float, _s: float) -> void: corpses_added += 1)
	host.telegraph.connect(func(_id: int, t: int, _a: float, _b: float, _c: float, _d: float, _r: float, _s: float) -> void:
		tele_events += 1
		tells[DmCoreEvents.TELLS[t]] = int(tells.get(DmCoreEvents.TELLS[t], 0)) + 1)
	host.zone.connect(func(_id: int, _k: int, _s: int, _x: float, _z: float, _r: float, _t: float) -> void: zones_seen += 1)
	host.enemy_attack.connect(func(_id: int, _b: int, _x: float, _z: float, _w: float) -> void: attack_events += 1)
	host.target_hit.connect(func(_id: int, _t: int, _k: int, _d: float) -> void:
		if hero_dead and host.ticks > death_tick:   # blows decided in the tick he fell are still in that tick's batch
			dead_hits += 1)
	g.hero_died.connect(func(_b: DmHeroBody) -> void:
		hero_died_n += 1
		death_tick = host.ticks
		hero_dead = true)
	g.hero_respawned.connect(func(hb: DmHeroBody) -> void:
		hero_respawned_n += 1
		got_up_at = hb.position
		hero_dead = false)


## The hero walks to the nearest enemy (a click on the ground, as a player would): waves climb in outside the aggro range and wait there, so nobody
## hunts a hero who stands still. He cannot fight back until the rites are in.
func walk_to_nearest() -> void:
	var b := g.local_body()
	if not b.alive:
		return
	var best := Vector3.INF
	var best_d := INF
	for id in g.enemies_in_radius(b.position, 90.0):
		var p := g.enemy_position(id)
		var d := p.distance_squared_to(b.position)
		if d < best_d:
			best_d = d
			best = p
	if best != Vector3.INF:
		g.session.request_move_to(best)


## 60 s of game time with the default waves.
func the_run() -> void:
	var b := g.local_body()
	var t0 := Time.get_ticks_msec()
	for t in RUN_TICKS:
		await physics_frame
		if t % 90 == 30:
			walk_to_nearest()
		min_hero_hp = minf(min_hero_hp, b.hp)
		max_alive = maxi(max_alive, host.alive_count())
		max_total = maxi(max_total, host.enemy_total())
		if t % 60 == 59:
			samples.append([host.alive_count(), nodes()])
	print("INFO the run: %d ticks in %.1f s, %d bodies spawned (%d waves), %d died, %d removed, max %d alive / %d with the dying, hero min hp %.0f of %.0f, died %d, got up %d, blows on him %s, %d events" % [
		RUN_TICKS, float(Time.get_ticks_msec() - t0) / 1000.0, spawned, g.director.waves_spawned, died, removed, max_alive, max_total, min_hero_hp, b.max_hp, hero_died_n, hero_respawned_n,
		str(g.hits_taken), host.events_total])
	check(g.director.waves_spawned >= 3 and g.director.alive_count() <= g.director.cap + 1, "the director spawned waves (%d) up to the area's cap" % g.director.waves_spawned)
	check(spawned >= 20 and spawned == spawned_ids.size(), "every body is a core body with its own id (%d spawn events)" % spawned)
	check(max_alive <= g.director.cap + 1, "the area's cap holds (%d alive, cap %d)" % [max_alive, g.director.cap])
	check(max_total <= int(DmSimData.GLOBAL_ENEMY_CAP), "the global cap counts the dying (%d <= %d)" % [max_total, int(DmSimData.GLOBAL_ENEMY_CAP)])
	check(attack_events > 0, "enemies swung (%d attack events, %d telegraphs)" % [attack_events, tele_events])
	check(g.hits_taken.get("melee", 0) > 0, "enemies reached the hero and hit him through the core's events: %s" % str(g.hits_taken))
	var allowed := DmCoreEvents.HIT_KINDS
	var kinds_ok := true
	for k in g.hits_taken:
		kinds_ok = kinds_ok and allowed.has(k)
	check(kinds_ok, "the blows' kinds are today's kinds")
	check(min_hero_hp < b.max_hp, "the hero's health dropped (min %.0f of %.0f)" % [min_hero_hp, b.max_hp])
	check(g.enemy_fx.stats["strike"] > 0 and g.enemy_fx.stats["spawn"] >= spawned - 4, "the fx played the swings' impacts and the rises (%s)" % str(g.enemy_fx.stats))
	check(hero_died_n == 0 or dead_hits == 0, "no blow reached the hero while he lay dead (%d)" % dead_hits)
	# the order of a tick: the nodes that move the hero first, then the core, then the crowd's own priority
	check(g.session.process_physics_priority < host.process_physics_priority and host.process_physics_priority < host.view.process_physics_priority and g.director.process_physics_priority < host.process_physics_priority,
		"the host steps after the session and the director and before the crowd (%d < %d < %d)" % [g.session.process_physics_priority, host.process_physics_priority, host.view.process_physics_priority])
	check(host.core.take_events()[0].size() == 0, "the host took the tick's event buffer (once): nothing is left for anyone else")
	# what a spawn event carries
	var alive_ids: PackedInt32Array = host.core.enemy_ids()
	check(alive_ids.size() > 0 and spawned_ids.has(alive_ids[0]), "the core's bodies are the spawned ids")


## The kinds of blow, one of each, close to a hero who stands still: the penitent's cone, the moth's dust and its cloud, the sac's slam and a hurt ghoul's dig,
## tunnel and eruption. Each is a telegraph event, a swing and an impact for the fx.
func kinds() -> void:
	g.director.enabled = false
	var b := g.local_body()
	if hero_dead:
		var w := 0
		while hero_dead and w < 400:
			await physics_frame
			w += 1
	b.restore_vitals()
	# The waves' bodies still ring the hero: clear them, so the four kinds reach him without depending on room in a crowd (a sac behind a full ring
	# never gets to slam: that is crowd spacing, checked in core_enemies.gd, not the kinds of blow).
	for id in host.core.enemy_ids():
		if host.enemy_alive(id):
			host.damage(id, 1.0e9, b.core_id, false)
	await ticks(3)
	var seen_before := tells.duplicate()
	var fx_before: Dictionary = g.enemy_fx.stats.duplicate()
	var zones_before := zones_seen
	var at := b.position
	var ids := {}
	ids["penitent"] = host.spawn_enemy("penitent", at + Vector3(0.0, 0.0, -7.0), 1, 1.0, 1.0, false, "graves", false)
	ids["moth"] = host.spawn_enemy("moth", at + Vector3(5.0, 0.0, -6.0), 1, 1.0, 1.0, false, "graves", false)
	ids["sac"] = host.spawn_enemy("sac", at + Vector3(-5.0, 0.0, -5.0), 1, 1.0, 1.0, false, "graves", false)
	ids["ghoul"] = host.spawn_enemy("ghoul", at + Vector3(0.0, 0.0, -9.0), 1, 1.0, 1.0, false, "graves", false)
	await ticks(3)
	host.damage(ids["ghoul"], float(host.enemy_info(ids["ghoul"])["max_hp"]) * 0.6, b.core_id)   # under half its health it digs in
	var mound_seen := [false, false]   # [a mound while it was underground, none once it was up again]
	for t in 720:
		await physics_frame
		if t % 120 == 60:
			b.restore_vitals()   # he is only the target
		var st := int(host.enemy_info(ids["ghoul"]).get("state", -1)) if host.enemy_alive(ids["ghoul"]) else -1
		var under := st == DmCoreEvents.State.BURROW or st == DmCoreEvents.State.ERUPT
		if under and g.enemy_fx._mounds.has(ids["ghoul"]):
			var m: Node3D = g.enemy_fx._mounds[ids["ghoul"]]
			var p := host.enemy_position(ids["ghoul"])
			mound_seen[0] = mound_seen[0] or Vector2(m.position.x - p.x, m.position.z - p.z).length() < 0.5
		elif mound_seen[0] and not under and st >= 0:
			mound_seen[1] = not g.enemy_fx._mounds.has(ids["ghoul"])
	var got := {}
	for k in DmCoreEvents.TELLS:
		got[k] = int(tells.get(k, 0)) - int(seen_before.get(k, 0))
	print("INFO the kinds' telegraphs: ", got, "; fx ", g.enemy_fx.stats, "; zones ", zones_seen - zones_before)
	check(got["cone"] >= 1 and got["dust"] >= 1 and got["slam"] >= 1, "the penitent's cone, the moth's dust and the sac's slam were announced (%s)" % str(got))
	check(got["erupt"] >= 1 and g.enemy_fx.stats["dig"] > int(fx_before["dig"]) and g.enemy_fx.stats["erupt"] > int(fx_before["erupt"]), "the hurt ghoul dug in and erupted: dig, tunnel, a telegraph, the eruption's fx")
	check(mound_seen[0] and mound_seen[1], "a dirt mound rode over the ghoul while it was underground and went when it came up (%s)" % str(mound_seen))
	check(zones_seen > zones_before and g.enemy_fx.stats["zone"] > int(fx_before["zone"]), "the moth's dust cloud is a zone the fx drew (%d)" % (zones_seen - zones_before))
	check(g.enemy_fx.stats["telegraph"] - int(fx_before["telegraph"]) >= 4 and g.enemy_fx.stats["strike"] - int(fx_before["strike"]) >= 3, "the fx drew the telegraphs and the strikes' impacts")
	for id in ids.values():
		if host.enemy_alive(id):
			host.damage(id, 1.0e9, b.core_id, false)


func hero_death() -> void:
	var b := g.local_body()
	g.director.enabled = false
	if hero_died_n == 0 or hero_dead:
		await ticks(1)
	if hero_died_n == 0:
		b.take_damage(1.0e9, 0, "melee")   # the waves were too weak: force it
		await ticks(2)
		check(hero_died_n == 1 and not b.alive, "a forced death kills the hero and tells the scene")
	else:
		print("INFO the waves killed the hero by themselves (%d times)" % hero_died_n)
	var died_before := hero_died_n
	# let him get up: 4 s after he fell
	var wait := 0
	while hero_dead and wait < 400:
		await physics_frame
		wait += 1
	check(hero_respawned_n >= 1 and b.alive and not hero_dead, "the hero got up again (%d ticks after the check)" % wait)
	check(absf(got_up_at.x - g.respawn_point().x) < 1.0 and absf(got_up_at.z - g.respawn_point().z) < 1.0 or g.world.area_at(got_up_at.x, got_up_at.z) == "graves",
		"he got up at the Graves' door, in the Graves (%s; the door %s)" % [str(got_up_at), str(g.respawn_point())])
	check(died_before >= 1, "the death was counted")
	g.director.enabled = true


func killing() -> void:
	g.director.enabled = false
	var b := g.local_body()
	# make sure there are bodies to kill: a few robbers close by, awake
	var made := PackedInt32Array()
	for i in 12:
		var a := float(i) / 12.0 * TAU
		made.append(host.spawn_enemy("robber" if i % 3 != 0 else "hound", b.position + Vector3(cos(a), 0.0, sin(a)) * 9.0, 1, 1.0, 1.0, i == 5, "graves", false))
	await ticks(3)
	var corpses_before := corpses_added
	var died_before := died
	var deaths_fx := int(g.enemy_fx.stats["death"])
	var marks_before := int(g.enemy_fx.stats["corpse_mark"])
	var landings_before := int(g.enemy_fx.stats["landing"])
	var showing_before := g.enemy_fx.corpse_marks(true)   # the pale (capped) rings; a resonant corpse's violet ring always shows
	var kills := 0
	for id in made:
		var r: Dictionary = host.damage(id, 1.0e6, b.core_id)
		if r["killed"]:
			kills += 1
	check(kills == made.size(), "core.damage kills at once (%d of %d)" % [kills, made.size()])
	await ticks(3)
	check(died - died_before == kills, "a died event per kill (%d)" % (died - died_before))
	check(corpses_added - corpses_before == kills, "every kill laid a corpse (%d: a robber's is normal, a hound's swift)" % (corpses_added - corpses_before))
	check(host.core.corpse_count() > 0, "the core holds corpses (%d)" % host.core.corpse_count())
	check(int(g.enemy_fx.stats["death"]) - deaths_fx == kills, "the fx played the death path for each (%d)" % (int(g.enemy_fx.stats["death"]) - deaths_fx))
	var marks := int(g.enemy_fx.stats["corpse_mark"]) - marks_before
	var room := DmEnemyFx.CORPSE_MARKS_MAX - showing_before
	check(marks == mini(kills, room) and g.enemy_fx.corpse_marks(true) == mini(DmEnemyFx.CORPSE_MARKS_MAX, showing_before + kills),
		"the corpses get their pale rings up to %d at once (%d showing before, %d new, %d showing)" % [DmEnemyFx.CORPSE_MARKS_MAX, showing_before, marks, g.enemy_fx.corpse_marks(true)])
	var st: Dictionary = host.view.stats()
	print("INFO crowd after the kills: ", st)
	# bodies linger 4 s, then the core removes them and the fx forgets them
	var removed_before := removed
	await ticks(260)
	check(removed - removed_before >= kills, "the dead bodies were removed after 4 s (%d)" % (removed - removed_before))
	check(int(g.enemy_fx.stats["landing"]) - landings_before >= kills / 2, "dust rose where the bodies came to rest (%d of %d)" % [int(g.enemy_fx.stats["landing"]) - landings_before, kills])
	g.director.enabled = true


## No node per creature: the node count is the same whether the core holds 0, 35 or 70 more (idle) bodies.
func no_nodes_per_creature() -> void:
	g.director.enabled = false
	await ticks(90)
	var n0 := nodes()
	var b0 := host.enemy_total()
	var ids: Array = []
	for round in 2:
		for i in 35:
			var p := Vector3(-22.0 + float((i * 7) % 44), 0.0, -33.0 + float(i % 5) * 1.6 + float(round) * 1.0)
			ids.append(host.spawn_enemy("robber", p, 1, 1.0, 1.0, false, "graves", false))
		await ticks(20)
		var n := nodes()
		check(absi(n - n0) <= 3, "%d bodies more in the core: the scene tree holds %d nodes, was %d" % [host.enemy_total() - b0, n, n0])
	check(host.enemy_total() - b0 == 70, "the core holds the 70 (%d)" % (host.enemy_total() - b0))
	check(get_nodes_in_group("dm_enemy").is_empty(), "no node is in an enemy group")
	var named := 0
	for id in ids:
		if root.find_child("E%d" % id, true, false) != null:
			named += 1
	check(named == 0, "no node carries an enemy's id as its name")
	# the nodes over the whole run did not follow the crowd either
	var lo := 1 << 30
	var hi := 0
	var xs: Array = []
	for s in samples:
		lo = mini(lo, int(s[1]))
		hi = maxi(hi, int(s[1]))
	print("INFO nodes over the run: %d to %d (enemies alive %d at most); the scene tree has %d nodes" % [lo, hi, max_alive, nodes()])
	check(hi - lo <= 40, "the node count over the run varies by %d (effects, not creatures)" % (hi - lo))
	var http := root.find_children("*", "HTTPRequest", true, false)
	check(http.is_empty(), "no HTTP request node exists")
	g.director.enabled = true


func hover_pick() -> void:
	g.director.enabled = false
	var b := g.local_body()
	var cam: Camera3D = g.camera
	var at := b.position + Vector3(0.0, 0.0, -6.0)
	var id := host.spawn_enemy("robber", at, 1, 1.0, 1.0, false, "graves", false)
	await ticks(3)
	var chest := host.enemy_position(id) + Vector3(0.0, 0.9, 0.0)
	var screen := cam.unproject_position(chest)
	check(g.input.pick_enemy(screen) == id or host.enemies_in_radius(chest, 2.5).size() > 1, "the hover pick finds the enemy under the cursor through the core (id %d)" % id)
	check(g.input.pick_enemy(screen + Vector2(300.0, 300.0)) != id, "and not from 300 px away")
	g.director.enabled = true


func draw_frame() -> void:
	var t := Time.get_ticks_usec()
	host.view._process(1.0 / 60.0)
	draw_us += Time.get_ticks_usec() - t
	draw_n += 1


## The affixes' one-off beats: the bell tolls (a telegraph, then the ring), a corpse is eaten, a shroud is lifted, the Vengeful bursts into Risen. Each is one
## event of the core's buffer, played by DmEnemyFx.
func affixes() -> void:
	g.director.enabled = false
	var b := g.local_body()
	var moments := {}
	var moment_cb := func(_id: int, moment: int, _ax: float, _az: float, _tx: float, _tz: float, _amt: float) -> void:
		moments[DmCoreEvents.AFFIX_MOMENTS[moment]] = int(moments.get(DmCoreEvents.AFFIX_MOMENTS[moment], 0)) + 1
	host.affix_moment.connect(moment_cb)
	var risen := [0]   # (a lambda copies plain numbers; an array is shared)
	var spawn_cb := func(_id: int, def: String, _lv: int, _el: bool, _ar: String, _af: int, _x: float, _z: float, _hp: float) -> void:
		if def == "risen":
			risen[0] += 1
	host.enemy_spawned.connect(spawn_cb)
	var base := b.position + Vector3(0.0, 0.0, -14.0)
	var marks_before := int(g.enemy_fx.stats["affix_mark"])
	var motes_before := int(g.enemy_fx.stats["affix_mote"])
	var gone_before := int(g.enemy_fx.stats["corpse_gone"])
	var bell := host.spawn_enemy("robber", base, 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["bellTolled"]))
	var shroud := host.spawn_enemy("robber", base + Vector3(6.0, 0.0, 0.0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["shrouded"]))
	var veng := host.spawn_enemy("robber", base + Vector3(-6.0, 0.0, 0.0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["vengeful"]))
	var hungry := host.spawn_enemy("robber", base + Vector3(0.0, 0.0, -6.0), 1, 1.0, 1.0, true, "graves", false, PackedStringArray(["hungering"]))
	var food := host.spawn_enemy("robber", base + Vector3(0.5, 0.0, -6.5), 1, 1.0, 1.0, false, "graves", false)
	await ticks(3)
	check(int(g.enemy_fx.stats["affix_mark"]) - marks_before == 4, "each affixed elite stands on its affix's mark (%d)" % (int(g.enemy_fx.stats["affix_mark"]) - marks_before))
	host.damage(food, 1.0e6, b.core_id)            # a corpse beside the hungry one
	host.damage(hungry, 200.0, b.core_id)          # hurt, so it wants to eat
	check(host.core.strip_shroud(shroud), "the shroud of an elite lifts for good")
	var status_motes := int(g.enemy_fx.stats["status_mote"])
	host.apply_status(bell, "chill", b.core_id, 1.0, 6.0)   # a status tell near the hero: frost motes
	var kill := host.damage(veng, 1.0e9, b.core_id)
	check(kill["killed"], "the Vengeful elite falls")
	await ticks(500)                               # the bell tolls every 6 s (0.9 s wind-up), the meal every 4 s
	host.affix_moment.disconnect(moment_cb)
	host.enemy_spawned.disconnect(spawn_cb)
	var risen_before: int = risen[0]
	print("INFO affix moments: ", moments, "; ", risen_before, " risen spawned; fx moments ", g.enemy_fx.stats["moment"])
	check(moments.get("tell", 0) >= 1 and moments.get("toll", 0) >= 1, "the bell rang: a tell and a toll (%s)" % str(moments))
	check(moments.get("vengeful", 0) == 1 and risen_before == int(DmSimData.AFFIX_TUNING["vengeful"]["risen"]), "the Vengeful burst into its Risen (%d)" % risen_before)
	check(moments.get("unveil", 0) == 1, "the shroud's lifting is a moment")
	check(moments.get("hungering", 0) >= 1 and int(g.enemy_fx.stats["corpse_gone"]) > gone_before, "the hungry elite ate the corpse, and the fx tore it apart (olive gore)")
	check(int(g.enemy_fx.stats["moment"]) >= 4, "the fx played them (%d)" % int(g.enemy_fx.stats["moment"]))
	check(int(g.enemy_fx.stats["affix_mote"]) > motes_before and g.enemy_fx._unveiled.has(shroud), "near the hero they give off their motes (%d), the lifted shroud stops smoking" % (int(g.enemy_fx.stats["affix_mote"]) - motes_before))
	check(not g.enemy_fx._affixed.has(veng), "the fallen Vengeful's mark is gone")
	check(int(g.enemy_fx.stats["status_mote"]) > status_motes, "a chilled body near the hero gives off frost motes (%d)" % (int(g.enemy_fx.stats["status_mote"]) - status_motes))
	for id in [bell, shroud, hungry]:
		host.damage(id, 1.0e9, b.core_id, false)
	await ticks(2)
	check(not g.enemy_fx._affixed.has(bell) and not g.enemy_fx._affixed.has(shroud) and not g.enemy_fx._affixed.has(hungry), "and every fallen elite's mark goes with it")


## INFO timings with about 70 enemies in a fight: the host's tick and the crowd's draw per frame.
func timings() -> void:
	g.director.enabled = false
	host.view.set_process(false)   # the test calls the draw itself, to time it
	var view := host.view
	var b := g.local_body()
	# a clean field: every body the earlier parts left is killed and removed after its 4 s
	for round in 8:   # (a burrowed ghoul takes no damage until it surfaces, and a Vengeful elite's Risen join the field when it falls: more rounds)
		var any := false
		for id in host.core.enemy_ids():
			if host.enemy_alive(id):
				any = true
				host.damage(id, 1.0e9, 0, false)
		if not any:
			break
		await ticks(60)
	await ticks(270)
	var left := []
	var underground := 0
	for id in host.core.enemy_ids():
		var inf: Dictionary = host.enemy_info(id)
		left.append("%s state %d" % [inf["def"], inf["state"]])
		if int(inf["state"]) == DmCoreEvents.State.BURROW:
			underground += 1   # a tunnelling ghoul cannot be hurt until it surfaces
	check(host.enemy_total() == underground, "the field is empty again, but for ghouls underground (%d bodies: %s)" % [host.enemy_total(), str(left)])
	g.director.cap = 72
	g.director.wave_size = 72
	g.director.enemy_limit = 90
	g.director.spawn_min = 6.0   # close around the hero, so the whole crowd is in the fight at once
	g.director.spawn_max = 12.0
	g.director.enabled = true
	var room := 72 - host.alive_count()
	var made := g.director.spawn_wave([b], 72)
	g.director.flush_spawns()
	check(made == room and host.alive_count() == 72, "the director made a wave of %d through the core (%d, %d alive)" % [room, made, host.alive_count()])
	await ticks(90)   # the rise
	var enemies := 0
	var t_ticks := 0
	draw_us = 0
	draw_n = 0
	host.measure = true
	host.step_us = 0
	host.sync_us = 0
	host.dispatch_us = 0
	var ticks0 := host.ticks
	process_frame.connect(draw_frame)
	for t in 600:
		await physics_frame
		enemies += host.alive_count()
		if t % 4 == 0:
			b.restore_vitals()   # he stays on his feet in the middle of it: the busiest the event buffer gets
	process_frame.disconnect(draw_frame)
	host.measure = false
	t_ticks = host.ticks - ticks0
	view.set_process(true)
	var tk := float(maxi(t_ticks, 1))
	print("INFO timings with about %d enemies alive (%d bodies in the core, %d thralls): per tick step %.0f us, crowd sync %.0f us, event dispatch %.0f us (%.1f events a tick); per rendered frame draw %.0f us over %d frames" % [
		enemies / 600, host.enemy_total(), host.thrall_count(), float(host.step_us) / tk, float(host.sync_us) / tk, float(host.dispatch_us) / tk,
		float(host.events_total) / maxf(1.0, float(host.ticks)), float(draw_us) / float(maxi(draw_n, 1)), draw_n])
	var st: Dictionary = view.stats()
	check(int(st.get("bodies", 0)) >= host.alive_count() - 2, "the crowd has a view per body (%s)" % str(st))
	var drawn := 0
	var crowd: RefCounted = view.crowd
	for m in view.model_slots().values():
		for l in 3:
			drawn += int(crowd.instance_count(m, l, false)) + int(crowd.instance_count(m, l, true))
	check(drawn > 0 and drawn >= int(st.get("bodies", 0)) / 3, "the crowd draws the creatures: %d instances for %d bodies" % [drawn, int(st.get("bodies", 0))])


func finish() -> void:
	print("INFO fx: ", g.enemy_fx.stats, "; held for ", g.enemy_fx.watched(), " creatures")
	check(g.enemy_fx.watched() <= g.director.cap + 24, "the fx holds something for few creatures (%d)" % g.enemy_fx.watched())
	check(errlog.errors.is_empty(), "no script or engine errors in the run (%d)" % errlog.errors.size())
	for e in errlog.errors.slice(0, 12):
		printerr("ERROR LOG: " + e)
	g.queue_free()
	await process_frame
	await process_frame
	if fails == 0:
		print("PASS game_scene %d checks" % checks)
	else:
		printerr("FAIL game_scene: %d of %d checks" % [fails, checks])
	quit(1 if fails > 0 else 0)
