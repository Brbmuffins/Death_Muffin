class_name DmBenchFight
extends RefCounted
## The held test fight of the in-game benchmark (DmBenchmark), on the combat core: an isolated offline game (DmOffline mock backend with an
## in-memory db, nothing persisted, no network), a god-mode level-60 necromancer in the middle of an area on auto combat (Easy), enemies topped up by the wave director, thralls
## raised straight into the core and, in a Full Party fight, the room's boss held awake. `arm` + `upkeep` are the fight's rules. Enemies are ids in the core: counting, trimming and
## topping up read its bulk arrays and call `remove_enemy`, nothing walks nodes.


## Builds the game under `parent` and returns {game, hero, caster, api, mock, stats, at}. `stats.calls` counts the requests the mock served.
## `opts` is merged over the game's start options (seed, the HUD on the core, the warm-up forced on, the benchmark's own director seed, and `areas`: only `area` is loaded, so the run
## measures the room and not the world); Easy auto combat is opened for the fight (the game has no settings store yet to open it) and the director follows Easy. The director is off until `arm`: the hero starts inside the room (it is the only area), and a wave made
## before the fight's rules are set would be on play's health and distances.
static func boot(parent: Node, disc: int, opts: Dictionary = {}, area: String = "graves") -> Dictionary:
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
	var o := {"name": "benchmark", "persist": false, "warmup": true, "hud": true, "waves": false, "seed": DmBenchmark.SEED, "areas": [area]}
	o.merge(opts, true)
	await g.start(c.data, api, o)
	var tree := parent.get_tree()
	for i in 30:
		await tree.process_frame
	var hero := g.local_body()
	hero.p["god"] = true
	var caster := hero.get_node("Rites") as DmRiteCaster
	caster.p["stats"]["level"] = 60.0
	g.input.auto.gate_probe = func() -> bool: return true   # Easy auto combat is on for the fight (the setting that opens it does not exist yet)
	g.director.difficulty = "easy"
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
## corpses don't stall spawning, every enemy on the standard health, the hero holding its ground (auto combat casts without walking). Switches the waves on.
static func arm(g: DmNextGame, enemies: int, seed_: int) -> void:
	g.director.surge = null   # no Grave Surge: it would add bodies to the counts the fight holds (a full run is about 90 s, the first surge opens at 100 s of hero time)
	g.director.enabled = true
	g.director.rng.seed = seed_
	g.director.spawn_min = DmBenchmark.SPAWN_MIN_M
	g.director.spawn_max = DmBenchmark.SPAWN_MAX_M
	g.director.cap = enemies
	g.director.enemy_limit = DmBenchmark.ENEMY_LIMIT
	g.director.fixed_stats = DmBenchmark.standard_stats()
	g.input.auto.hold_position = true


## One upkeep step (the benchmark runs it every DmBenchmark.TICK_S): enemies and thralls back to their targets, the room's `boss` awake (""
## = none), the hero unkillable. `f` is `boot`'s result. Returns how many thralls the hero's legion holds.
static func upkeep(f: Dictionary, enemies: int, thralls: int, boss: String) -> int:
	var g: DmNextGame = f["game"]
	var hero: DmHeroBody = f["hero"]
	g.director.cap = enemies   # (configure_area resets it when the director follows the hero into the room)
	top_up(g, hero, enemies)
	trim(g, hero, enemies)
	var held := raise_thralls(g, hero, thralls, f["at"])
	if boss != "":
		hold_boss(g, hero, boss, f["at"])
	hero.heal(1e6)
	return held


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


## Holds the count at `n`: raisers (Vengeful's Risen, a boss's adds) add bodies beyond the director's cap, so the farthest extras are removed quietly
## (`remove_enemy`: no death, no corpse, no reward). Benchmark only: play keeps its raisers. Reads the core's bulk arrays; allocates only when there is something to trim.
static func trim(g: DmNextGame, hero: DmHeroBody, n: int) -> void:
	var host: DmCoreHost = g.core_host
	if host.alive_count() <= n:
		return
	var ids: PackedInt32Array = host.core.enemy_ids()
	var pos: PackedFloat32Array = host.core.enemy_positions()
	var states: PackedInt32Array = host.core.enemy_states()
	var live: Array = []
	for i in ids.size():
		if states[i] == DmCoreEvents.State.DEAD:
			continue
		var dx := pos[i * 3] - hero.global_position.x
		var dz := pos[i * 3 + 1] - hero.global_position.z
		live.append([dx * dx + dz * dz, ids[i]])
	if live.size() <= n:
		return
	live.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i in live.size() - n:
		host.remove_enemy(int(live[i][1]))


## Thralls raised directly (no corpses needed, no cap) until the hero's legion holds `want`; returns how many it holds.
static func raise_thralls(g: DmNextGame, hero: DmHeroBody, want: int, at: Vector3) -> int:
	var host: DmCoreHost = g.core_host
	var have := host.thrall_count(hero.core_id)
	for i in range(have, want):
		var st := DmThralls.raise_stats({"kind": ["warrior", "archer", "wraith"][i % 3], "hp": 1e6, "damage": 30.0, "attackSpeedMult": 1.0},
			{"kind": "normal", "enemy": "risen", "elite": false}, 1.0, i + 1, 0.0)
		var p := at + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3))
		host.core.raise_thrall(st, hero.core_id, Vector2(p.x, p.z), 0.0, -1.0)
	return host.thrall_count(hero.core_id)


## The boss that sleeps in `area` ("" = none: the Warren and the Coliseum have no boss). A boss only wakes for heroes standing in its own area, so a room's fight holds that room's boss
## (the boss host wakes all seven); the Bell Sanctum's Prelate has the whole room for its arena (radius 13 m in a 36 x 28 m room).
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
