class_name DmBenchFight
extends RefCounted
## The held test fight shared by the in-game benchmark (DmBenchmark) and the headless probe tests/perf/fight_breakdown.gd: an isolated
## offline game (DmOffline mock backend with an in-memory db, nothing persisted, no network), a god-mode level-60 necromancer in the middle
## of an area on auto combat (Easy), enemies topped up by the wave director, thralls raised directly and, in a Full Party fight, the room's boss
## held awake. `arm` + `upkeep` are the fight's rules, so the benchmark and the probe hold the same fight.


## Builds the game under `parent` and returns {game, hero, caster, api, mock, stats, at}. `stats.calls` counts the requests the mock served.
## `opts` is merged over the game's start options (persist off, warm-up forced, dressing, HUD); `settings` is patched into the settings
## store (in memory) once the HUD exists, so the game runs on the same path as a real Settings change.
static func boot(parent: Node, disc: int, opts: Dictionary = {}, settings: Dictionary = {}, area: String = "graves") -> Dictionary:
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var stats := {"calls": 0}
	var inner: Callable = api.transport
	api.transport = func(req: Dictionary) -> Variant:
		stats["calls"] += 1
		return inner.call(req)
	var r := await api.register("fb%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(disc)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	parent.add_child(g)
	var o := {"persist": false, "warmup": true, "dressing": true, "hud": true}
	o.merge(opts, true)
	await g.start(c.data, api, o)
	var tree := parent.get_tree()
	for i in 30:
		await tree.process_frame
	var hero := g.local_body()
	hero.p["god"] = true
	var caster := hero.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	var store: DmSettings = g.ui_host.settings_store
	store.set_active_character(int(g.character.get("id", 1)), true)
	var patch := {"difficulty": "easy", "auto_combat": true, "graphics": "high"}
	patch.merge(settings, true)
	store.update(patch)
	# A fresh character has most areas sealed, and a sealed area's navmesh is switched off: enemies inside could not path anywhere (they
	# all walked to the doorway strip). The throwaway character breaks the area's seal through its own progression, and the world applies it.
	if g.ui_host != null and g.ui_host.prog != null and g.ui_host.prog.unlock(area) and g.chapterhouse != null:
		g.chapterhouse.apply_seals()
	var rect: Dictionary = DmContent.area(area)["rect"]
	var at := Vector3((float(rect["x0"]) + float(rect["x1"])) / 2.0, 0.0, (float(rect["z0"]) + float(rect["z1"])) / 2.0)
	if g.world != null:
		at = connected_spot(g, area, at)   # the centre may be a cut-off dais (the Bell Sanctum's is): enemies could never reach the hero
	if g.director.area_id != area:
		g.director.configure_area(area)   # the area's roster and scaling for the ring spawns, whatever the director last followed
	hero.teleport(at)
	g.camera.snap(at)
	return {"game": g, "hero": hero, "caster": caster, "api": api, "mock": mock, "stats": stats, "at": at}


## The director set up the way the benchmark holds a fight: waves close to the hero (a small room), the cap at `enemies`, the body limit raised so
## corpses don't stall spawning, every enemy on the standard health, the hero holding its ground (auto combat casts without walking).
static func arm(g: DmNextGame, enemies: int, seed_: int) -> void:
	g.director.rng.seed = seed_
	g.director.spawn_min = DmBenchmark.SPAWN_MIN_M
	g.director.spawn_max = DmBenchmark.SPAWN_MAX_M
	g.director.cap = enemies
	g.director.enemy_limit = DmBenchmark.ENEMY_LIMIT
	g.director.fixed_stats = DmBenchmark.standard_stats()
	g.input.auto.hold_position = true


## One upkeep step (the benchmark runs it every DmBenchmark.TICK_S): enemies and thralls back to their targets, the room's `boss` awake (""
## = none), the hero unkillable. `f` is `boot`'s result. Returns the thrall host.
static func upkeep(f: Dictionary, enemies: int, thralls: int, boss: String) -> DmThrallHost:
	var g: DmNextGame = f["game"]
	var hero: DmHeroBody = f["hero"]
	g.director.cap = enemies   # (configure_area resets it when the director follows the hero into the room)
	top_up(g, hero, enemies)
	trim(g, hero, enemies)
	var host := raise_thralls(f["caster"], thralls, f["at"])
	if boss != "":
		hold_boss(g, hero, boss, f["at"])
	hero.heal(1e6)
	return host


## The walkable point nearest `centre` that a path joins to the area's doorway (so every enemy coming in can reach it). Rings of 1.5 m
## outward, 12 points each; falls back to the plain nearest walkable point.
static func connected_spot(g: DmNextGame, area: String, centre: Vector3) -> Vector3:
	var ref := Vector3.INF
	for d: Dictionary in DmContent.get_export("areas", "DOORS"):
		if String(d["a"]) == area or String(d["b"]) == area:
			var r: Dictionary = d["rect"]
			ref = g.world.nav_closest(Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5))
			break
	var first := g.world.nav_closest(centre)
	if ref == Vector3.INF:
		return first
	for ring in 9:
		var rad := ring * 1.5
		for k in (1 if ring == 0 else 12):
			var a := TAU * k / 12.0
			var p := g.world.nav_closest(centre + Vector3(sin(a), 0.0, cos(a)) * rad)
			var path := g.world.nav_path(p, ref)
			if not path.is_empty() and Vector2(path[-1].x - ref.x, path[-1].z - ref.z).length() < 1.5:
				return p
	return first


## Enemies alive up to `n` through the wave director's own spawn_wave (around the hero, at its spawn distance).
static func top_up(g: DmNextGame, hero: DmHeroBody, n: int) -> void:
	var alive := g.director.alive_count()
	if alive < n:
		g.director.spawn_wave([hero], n - alive)


## Holds the count at `n`: raisers (deacons, acolytes, a golem's split) add Risen beyond the director's cap, so the farthest extras are
## removed quietly (no death, no corpse, no reward). Benchmark only: play keeps its raisers.
static func trim(g: DmNextGame, hero: DmHeroBody, n: int) -> void:
	var live: Array = []
	for e in g.director.enemies.values():
		var en := e as DmEnemy
		if en != null and is_instance_valid(en) and en.sm != null and en.sm.id() != DmEnemyState.Id.DEAD and not en.is_queued_for_deletion():
			live.append([en.global_position.distance_squared_to(hero.global_position), en])
	if live.size() <= n:
		return
	live.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i in live.size() - n:
		(live[i][1] as DmEnemy).queue_free()


## Thralls raised directly (no corpses needed) until the legion holds `want`; returns the host.
static func raise_thralls(caster: DmRiteCaster, want: int, at: Vector3) -> DmThrallHost:
	var host: DmThrallHost = caster.thralls()
	for i in range(host.list().size(), want):
		var st := DmThralls.raise_stats({"kind": ["warrior", "archer", "wraith"][i % 3], "hp": 1e6, "damage": 30.0, "attackSpeedMult": 1.0},
			{"kind": "normal", "enemy": "risen", "elite": false}, 1.0, i + 1, 0.0)
		host._spawn(st, at + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3)), 0.0)
	return host


## The boss that sleeps in `area` ("" = none: the Warren and the Coliseum have no boss). A boss only wakes for heroes standing in its own area,
## so a room's fight holds that room's boss; the Bell Sanctum's Prelate has the whole room for its arena (radius 13 m in a 36 x 28 m room).
static func boss_of(area: String) -> String:
	for id: String in DmBossHost.LIVE:
		if String(DmContent.boss(id)["area"]) == area:
			return id
	return ""


## Wakes `boss` when none is awake (the one that was awake was defeated): the hero stands at the boss's site for the summon, with the soul shards
## it costs granted to the throwaway character, then goes back to `at`. The real summon path (shards spent, `try_summon`), so the boss, its rewards
## and drops cost what they cost in play. Returns true when it woke one.
static func hold_boss(g: DmNextGame, hero: DmHeroBody, boss: String, at: Vector3) -> bool:
	if g.bosses.active_boss() != null:
		return false
	var site: Vector3 = g.bosses.site_pos(boss)
	var m := g.my_member()
	if site == Vector3.INF or m == null:
		return false
	hero.teleport(site)
	m.prog.add_shards(int(DmContent.boss(boss)["shards"]))
	var why: String = g.bosses.try_summon(g.session.get_my_id(), boss)
	hero.teleport(at)
	if why != "":
		push_warning("[bench] the %s did not wake: %s" % [boss, why])
	return why == ""
