extends RefCounted
## THE shared harness of the boss suite (tests/next_bosses). Not a runner: every `*_part.gd` extends it and `run.gd` (one process) drives them all.
## It holds what every boss test needs: the counting fx back-ends, ONE solo game that is booted once and reset between bosses, the by-hand boss stepping
## (set_physics_process(false) + _physics_process(1/60): exact timing), the event log, the generic summon / defeat / rite / wipe checks, ONE two-peer ENet
## pair (booted once, each boss summoned on it in turn) and ONE crowd perf probe. A part is a RefCounted, so the few SceneTree things it needs
## (root, physics_frame, get_nodes_in_group, set_multiplayer) are shimmed below; the driver hands them in through `adopt()`.
## Lines print as `N passed, M failed`; the driver exits 1 on failure. BOSS_TRACE=1 prints every check as it runs (to place an engine error).

const DT := 1.0 / 60.0

var _trace := OS.get_environment("BOSS_TRACE") != ""


class ErrLog extends Logger:
	var errors: Array = []
	var suite: Object
	func _frames(bt: Array) -> String:
		var out := ""
		for b: ScriptBacktrace in bt:
			for i in mini(4, b.get_frame_count()):
				out += " < %s:%d %s" % [b.get_frame_file(i).get_file(), b.get_frame_line(i), b.get_frame_function(i)]
		return out
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor: bool, error_type: int, bt: Array) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			var at := "?"
			if suite != null:
				at = str(suite.passed + suite.failed)
			errors.append("%s:%d %s %s [after check %s in %s]%s" % [file.get_file(), line, code, rationale, at, suite.boss_id if suite != null else "-", _frames(bt)])


## Counting back-ends for the fx (every Vfx / AudioDirector call the router makes).
class Stub extends Node:
	var calls: Dictionary = {}
	var sfx: Array = []
	var particle_scale := 1.0
	var hitstop_scale := 1.0
	func _count(n: String) -> void:
		calls[n] = int(calls.get(n, 0)) + 1
	func danger(cb: Callable, _keep: bool = false) -> void:
		_count("danger")
		cb.call()
	func play_sfx(name_: String, _pos: Variant = null, _i: float = 1.0) -> bool:
		sfx.append(name_)
		return true
	class Handle extends RefCounted:
		var alive := true
		func kill() -> void:
			alive = false
	func decal(_o: Dictionary) -> Variant:
		_count("decal")
		return Handle.new()
	func emit(_o: Dictionary) -> void:
		_count("emit")
	func emit_smoke(_o: Dictionary) -> void:
		_count("emit")
	func light_flash(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void:
		_count("flash")
	func flash(_o: Dictionary) -> void:
		_count("flash")
	func spike_line(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null, _f: Variant = null) -> void:
		_count("spike")
	func beam(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null, _e: Variant = null) -> void:
		_count("beam")
	func projectile(_o: Dictionary) -> void:
		_count("proj")
	func play(_id: String, _a: Variant = null, _b: Variant = null) -> Variant:
		_count("bb")
		return Handle.new()
	func _get(_prop: StringName) -> Variant:
		return null


# ---- state shared between parts (handed over by adopt / export_to) ------------------------------------------------------------------------

const SHARED := ["tree", "root", "physics_frame", "api", "character", "log_", "g", "hb", "evs", "hurts", "PORT", "hg", "cg", "g_director_on"]

var tree: SceneTree
var root: Window
var physics_frame: Signal
var log_: ErrLog
var api: DmApi
var character: Dictionary
var g: DmNextGame               ## the ONE solo game (booted by the first part, reset by every `new_solo()`)
var hb: DmHeroBody
var evs: Array = []             ## [{t: room clock, ev}] every brain event of the active boss
var hurts: Array = []
var PORT := 0
var hg: DmNextGame              ## the ONE host / client pair
var cg: DmNextGame
var g_director_on := true

# ---- state of the part itself ---------------------------------------------------------------------------------------------------------------

var passed := 0
var failed := 0
var boss_id := ""
var god_mode := false           ## the hero is "unkillable" by huge hp (the late bosses' style) instead of being healed when low
var boss: DmBoss
var after_kill := Callable()    ## check_defeat calls it right after the lethal hit
var stub := Stub.new()          ## the fx back-ends of the solo game
var astub := Stub.new()
var hstub := Stub.new()         ## ... of the host / client pair (fresh for every boss summoned on it)
var cstub := Stub.new()
var hast := Stub.new()
var cast_ := Stub.new()
var hboss: DmBoss
var cboss: DmBoss


func adopt(ctx: Dictionary) -> void:
	for k in SHARED:
		if ctx.has(k):
			set(k, ctx[k])


func export_to(ctx: Dictionary) -> void:
	for k in SHARED:
		ctx[k] = get(k)


## Overridden by a part: the solo fight of one boss (needs `new_solo()` first) and, after every part's solo run, its two-peer checks on the shared pair.
func solo() -> void:
	pass


func net() -> void:
	pass


# ---- SceneTree shims ------------------------------------------------------------------------------------------------------------------------

func get_nodes_in_group(group: StringName) -> Array:
	return tree.get_nodes_in_group(group)


func set_multiplayer(mp: MultiplayerAPI, path: NodePath) -> void:
	tree.set_multiplayer(mp, path)


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)
	if _trace:
		print("#%d %s" % [passed + failed, what])


## `n` physics frames. A god-mode hero is kept unkillable on the way.
func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		if god_mode and hb != null and is_instance_valid(hb) and not hb.p.is_empty() and hb.alive and hb.p["stats"]["maxHp"] < 9.0e8:
			god(hb)
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


# ---- helpers -----------------------------------------------------------------------------------------------------------------------

func def() -> Dictionary:
	return DmContent.boss(boss_id)


func area() -> String:
	return String(def()["area"])


## The summoning site from the content (the area's `summonId` interactable); Vector3.INF if the content has none.
func site() -> Vector3:
	var out := Vector3.INF
	for it in DmContent.area(area()).get("interactables", []):
		if String(it["id"]) == String(def()["summonId"]):
			out = Vector3(float(it["x"]), 0.0, float(it["z"]))
	return out


## 2 m in front of the summoning site (inside the 4 m summon range).
func near_site() -> Vector3:
	return site() + Vector3(0.0, 0.0, 2.0)


## The arena's centre.
func arena() -> Vector3:
	return Vector3(float(def()["arena"]["x"]), 0.0, float(def()["arena"]["z"]))


func _new_game(opts: Dictionary, host_root: Node = null) -> DmNextGame:
	var n: DmNextGame = load("res://next/next_game.tscn").instantiate()
	(host_root if host_root != null else root).add_child(n)
	await n.start(character, api, opts)
	return n


## The solo game with the counting fx back-ends and the event / hurt logs wired. The first call boots it; every later call (the next boss) RESETS it:
## the boss, adds, pools, corpses, thralls, shards and logs are gone, the hero is back at the origin.
func new_solo() -> void:
	if g == null or not is_instance_valid(g):
		g = await _new_game({"dressing": false, "hud": false, "waves": false, "audio": false})
		hb = g.local_body()
		g_director_on = g.director.enabled
		g.bosses.brain_event.connect(func(ev: Dictionary, b: DmBoss) -> void:
			evs.append({"t": b.world.t, "ev": ev.duplicate(true)})
			if ev["t"] == "hurt":
				hurts.append(ev))
		await ticks(2)
	else:
		await _reset_solo()
	stub = Stub.new()
	astub = Stub.new()
	g.bosses.fx.set_backends(stub, astub)
	g.enemy_fx.set_backends(stub, astub)
	hb.p["stats"]["maxHp"] = 1.0e5   # the fight is about numbers, not about the hero surviving them
	hb.heal(1.0e6)
	if god_mode:
		god(hb)
	await ticks(2)


func _reset_solo() -> void:
	if boss != null and is_instance_valid(boss):
		boss.queue_free()
	boss = null
	for b in g.bosses.bosses.values():
		if is_instance_valid(b):
			(b as Node).queue_free()
	g.bosses.assume_area = ""
	g.bosses.fx.host.sink = Callable()
	g.director.enabled = g_director_on
	clear_adds()
	clear_zones()
	(hb.get_node("Thralls") as DmThrallHost).clear()
	for c in g.corpses.corpses.values().duplicate():
		g.corpses.consume((c as DmSimCorpse).id, 0, "consumed")
	g.corpses.echo_enabled = false
	hb.teleport(Vector3(0, 0, 20))
	set_shards(0)
	evs.clear()
	hurts.clear()
	await ticks(5)
	set_shards(0)


## Effectively unkillable: the numbers are read from the events, the hp only has to stay > 0.
func god(b: DmHeroBody) -> void:
	b.p["stats"]["maxHp"] = 1.0e9
	b.p["hp"] = 1.0e9
	b._mirror_from_state()


## Keep a hero alive between steps (god mode: huge hp, the progression resets the stats now and then; otherwise heal when low).
func _keep(b: DmHeroBody) -> void:
	if god_mode:
		if float(b.p["stats"]["maxHp"]) < 9.0e8 or b.hp < 9.0e8:
			god(b)
	elif b.hp < b.max_hp * 0.5:
		b.heal(1e6)


func member() -> DmRewardsMember:
	return g.rewards.members[int(character.get("id", 0))]


## The member's soul shards, set outright: the progression syncs with the backend when the hero changes area (a reply restores the saved count), so a test
## sets what it needs right before the call that spends it.
func set_shards(n: int) -> void:
	member().prog.local["shards"] = n


## Step the boss `secs` of room time by hand, keeping the hero alive so nothing kills it.
func step(secs: float) -> void:
	for i in int(round(secs / DT)):
		_keep(hb)
		boss._physics_process(DT)


func events(kind: String, ms_gt: float = -1.0) -> Array:
	var out: Array = []
	for e in evs:
		var ev: Dictionary = e["ev"]
		if ev["t"] == "boss" and ev["kind"] == kind and (ms_gt < 0.0 or float(ev.get("ms", 0.0)) > ms_gt):
			out.append(e)
	return out


func telegraphs(kind: String) -> Array:
	return events(kind, 0.0)


func impacts(kind: String) -> Array:
	return events(kind).filter(func(e: Dictionary) -> bool: return float(e["ev"].get("ms", 0.0)) == 0.0)


func dmg_scale() -> float:
	return (1.0 + 0.15 * (float(boss.brain.state["level"]) - 1.0)) * float(DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]["enemyDamageMult"])


## Hurts of exactly `base` x scale since index `from`.
func hurts_of(base: float, from: int = 0) -> Array:
	return hurts.slice(from).filter(func(h: Dictionary) -> bool: return absf(float(h["dmg"]) - base * dmg_scale()) < 1e-6)


## Step until `cond` (by hand), at most `limit` seconds; true if it held.
func step_until(cond: Callable, limit: float) -> bool:
	for i in int(limit / 0.05):
		if cond.call():
			return true
		step(0.05)
	return cond.call()


## One tick at a time until `cond` (exact event times); true if it held within `limit` seconds.
func tick_until(cond: Callable, limit: float) -> bool:
	for i in int(limit / DT):
		if cond.call():
			return true
		step(DT)
	return cond.call()


func zones(kind: StringName = &"") -> Array:
	return get_nodes_in_group(&"dm_hostile_zone").filter(func(z: Node) -> bool: return kind == &"" or (z as DmHostileZone).kind == kind)


func clear_zones() -> void:
	for z in get_nodes_in_group(&"dm_hostile_zone"):
		z.free()


func clear_adds() -> void:
	for e in g.director.enemies.values():
		(e as Node).queue_free()
	g.director.enemies.clear()


## Wake the boss as it is: the area is assumed, nothing is teleported or granted. Returns the refusal ("" = woken).
func wake() -> String:
	g.bosses.assume_area = area()
	var why := g.bosses.try_summon(g.session.get_my_id(), boss_id)
	if why == "":
		boss = g.bosses.active_boss()
		boss.set_physics_process(false)
		boss.world.refresh()
	return why


## Wake the boss with the hero at its site: shards are set, the area is assumed, the body is stepped by hand, the logs start empty. Returns the refusal.
func summon(shards: int = 20) -> String:
	g.bosses.assume_area = area()
	hb.teleport(near_site())
	set_shards(shards)
	evs.clear()
	hurts.clear()
	return wake()


## Hero next to the boss's site with `shards` more shards (the summon itself is the caller's).
func at_site(shards: int) -> void:
	hb.teleport(near_site())
	g.bosses.assume_area = area()
	member().prog.add_shards(shards)
	await ticks(2)


## Put the hero at `p` and refresh the brain's view of it.
func put(p: Vector3) -> void:
	hb.teleport(p)
	boss.world.refresh()


## Set the brain's hp (a plain `boss.hp = ` is only the body's mirror) as a fraction of max.
func set_hp(frac: float) -> void:
	boss.brain.state["hp"] = boss.max_hp * frac
	boss.hp = boss.max_hp * frac


## Drop the boss to `frac` of its max hp (through take_damage, like a hit) and run one tick so the phase change fires.
func wound(frac: float) -> void:
	boss.take_damage(boss.hp - boss.max_hp * frac, hb)
	step(0.1)


func end_fight() -> void:
	if boss != null and is_instance_valid(boss):
		boss.queue_free()
	await ticks(3)
	boss = null


func awaken_hp_ok(base_hp: float) -> bool:
	var diff: Dictionary = DmContent.get_export("difficulty", "DIFFICULTIES")["medium"]
	var want: float = base_hp * (1.0 + 0.22 * (float(boss.brain.state["level"]) - 1.0)) * float(diff["enemyHpMult"])
	return is_equal_approx(boss.max_hp, want) and boss.hp == boss.max_hp


# ---- generic checks every boss shares ----------------------------------------------------------------------------------------------------

## The summon prompt is the hub's (no fading toast): near the site "<kbd>E</kbd> Summon X · N shards", gone away from it and while a boss is awake (also
## for a hover over the site); key E wakes it; clicking the site (the hub's `interacted`) asks the same host. Ends with the boss gone again.
func check_prompt_and_key() -> void:
	var toasts: Array = []
	g.bosses.fx.host.sink = func(id: String, _ctx: Dictionary) -> void: toasts.append(id)
	var ch: DmChapterhouse = g.chapterhouse
	g.bosses.assume_area = area()
	hb.teleport(near_site())
	await ticks(45)   # past the host's 0.5 s tick, where the old "press E" toast fired
	ch._update_prompt(hb)
	check(ch.prompt_text == "<kbd>E</kbd> Summon %s · %d shards" % [def()["name"], int(def()["shards"])], "A: at the site the hub prompt reads '%s'" % ch.prompt_text)
	check(not toasts.has("toast"), "A: no fading toast any more")
	var it: Dictionary = {}
	for x in ch.interactables:
		if String(x["id"]) == String(def()["summonId"]):
			it = x
	ch.hover = it
	ch._update_prompt(hb)
	check(ch.prompt_text == "<kbd>Click</kbd> Summon %s · %d shards" % [def()["name"], int(def()["shards"])], "A: hovering the site shows the click prompt")
	ch.hover = null
	hb.teleport(Vector3(0, 0, 20))
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "A: away from the site: no prompt")
	hb.teleport(near_site())
	set_shards(int(def()["shards"]))
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_E
	ev.pressed = true
	g.bosses._unhandled_input(ev)
	check(g.bosses.active_boss() != null and g.bosses.active_boss().boss_id == boss_id and int(member().prog.local["shards"]) == 0, "A: key E at the site wakes it (its shards spent)")
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "A: the prompt hides while a boss is awake")
	ch.hover = it
	ch._update_prompt(hb)
	check(ch.prompt_text == null, "A: ...and the hover prompt of its site too")
	ch.hover = null
	g.bosses.fx.host.sink = Callable()
	hb.teleport(Vector3(0, 0, 20))   # leaving the area: it goes back to sleep (its adds leave with it)
	g.bosses.assume_area = ""
	await ticks(4)
	check(g.bosses.active_boss() == null and g.director.enemies.is_empty(), "A: (the prompt test's boss went back to sleep, nothing left behind)")


## Summon rules: far, not live, shards (none spent), the boss's own cost, busy, dead. Leaves the boss awake (`boss` set).
func check_summon_rules(cost: int, not_live: String) -> void:
	var peer := g.session.get_my_id()
	g.bosses.assume_area = area()
	hb.teleport(Vector3(0, 0, 20))
	check(g.bosses.try_summon(peer, boss_id) == "far", "A: summon refused away from the site (far)")
	check(g.bosses.try_summon(peer, not_live) == "unknown", "A: an id that is no boss is not summonable (%s)" % not_live)
	hb.teleport(near_site())
	await ticks(2)
	check(g.bosses.site_pos(boss_id).distance_to(site()) < 0.01 and site() != Vector3.INF, "A: the site is the area's %s interactable" % def()["summonId"])
	check(g.bosses.site_near(near_site(), 4.0) == boss_id, "A: site_near names the boss at its site")
	var m := member()
	set_shards(0)
	check(g.bosses.try_summon(peer, boss_id) == "shards" and g.bosses.active_boss() == null, "A: no shards -> refused, nothing woken")
	set_shards(cost - 1)
	check(g.bosses.try_summon(peer, boss_id) == "shards" and int(m.prog.local["shards"]) == cost - 1, "A: %d of %d shards is not enough and none are spent" % [cost - 1, cost])
	check(g.bosses.why_text("shards", boss_id, peer).contains(String(def()["summonLabel"])) and g.bosses.why_text("shards", boss_id, peer).contains("(you have %d)" % (cost - 1)), "A: the refusal names the site and the count")
	set_shards(cost + 2)
	var summoned: Array = []
	g.bosses.summoned.connect(func(b: String, p: int) -> void: summoned.append([b, p]))
	var spawned: Array = []
	g.bosses.boss_spawned.connect(func(b: DmBoss) -> void: spawned.append(b))
	var before := int(m.prog.local["shards"])
	evs.clear()
	check(g.bosses.try_summon(peer, boss_id) == "", "A: %d shards wake it" % (cost + 2))
	boss = g.bosses.active_boss()
	boss.set_physics_process(false)
	boss.world.refresh()
	check(int(m.prog.local["shards"]) == before - cost and summoned == [[boss_id, peer]], "A: the boss's own cost (%d shards) is spent, `summoned` fires" % cost)
	check(spawned.size() == 1 and boss.is_in_group(&"dm_boss") and boss.is_in_group(&"dm_enemy"), "A: DmBoss spawned (boss_spawned, group dm_boss + dm_enemy)")
	check(g.bosses.try_summon(peer, boss_id) == "busy" and int(m.prog.local["shards"]) == before - cost, "A: a second summon while it is awake is refused (busy), no shards taken")
	check(g.bosses.try_summon(999, boss_id) == "dead", "A: an unknown/dead summoner is refused")
	check(g.bosses.site_near(near_site(), 4.0) == boss_id, "A: (the prompt asks the hub: site_near still names it, the hub hides the prompt while awake)")


## Defeat: lethal hit -> DEAD at once, `defeated` names the killer, the member is paid (first kill unless `first` false), the report entry rides the
## next batch, sounds, the boss's adds leave with it. Returns the shard total dropped.
func check_defeat(first: bool, bonus_shards: int) -> int:
	var drops: Array = []
	g.rewards.loot_dropped.connect(func(_c: int, d: Dictionary, _p: Vector3) -> void: drops.append(d))
	var earned: Array = []
	g.rewards.boss_earned.connect(func(_c: int, id: String, f: bool, _p: Vector3) -> void: earned.append([id, f]))
	var reported: Array = []
	g.rewards.batch_reported.connect(func(b: int, r: Variant) -> void: reported.append([b, r]))
	var died: Array = []
	boss.died.connect(func(_e: DmEnemy) -> void: died.append(1))
	var defeated: Array = []
	g.bosses.defeated.connect(func(id: String, killer: int, _p: Vector3) -> void: defeated.append([id, killer]))
	put(arena() + Vector3(3.0, 0.0, 0.0))
	g.rewards.rng = func() -> float: return 0.5
	var m := member()
	var xp0: float = float(m.prog.character["experience"])
	var bosses0 := int(m.stats["bosses"])
	if String(boss.brain.state["state"]) == "sunk":   # a hit at the very end while sunk is refused: she must surface to die
		boss.brain.state["state"] = "idle"
	var adds_before := g.director.enemies.size()
	boss.take_damage(boss.hp + 1.0, hb)
	if after_kill.is_valid():
		after_kill.call()   # progression state straight after the kill (the backend sync that follows may restore the saved one)
	check(boss.hp == 0.0 and boss.sm.id() == DmEnemyState.Id.DEAD and not boss.is_hittable() and died.size() == 1, "A: lethal hit -> DEAD at once, died emitted")
	check(events("defeated").size() == 1 and str(events("defeated")[0]["ev"]["killer"]) == str(g.session.get_my_id()) and defeated == [[boss_id, g.session.get_my_id()]], "A: defeated event names the killer")
	check("bossDefeat" in astub.sfx, "A: bossDefeat sound")
	check(earned == [[boss_id, first]], "A: the member is paid (first kill: %s)" % first)
	var shards := 0
	for d in drops:
		if d.get("kind") == "shard":
			shards += int(d["amount"])
	check(drops.size() >= 2 and shards >= bonus_shards, "A: gold + shards + items dropped (%d drops, %d shards)" % [drops.size(), shards])
	check(float(m.prog.character["experience"]) > xp0 or int(m.stats["levels"]) > 0, "A: boss XP applied")
	check(int(m.stats["bosses"]) == bosses0 + 1 and m.reporter._bosses.size() == 1, "A: boss kill queued for the backend report {boss, tier, diff, first}")
	var key: String = m.reporter._bosses.keys()[0]
	check(key.begins_with("%s|" % boss_id) and key.contains("|%d|" % (1 if first else 0)), "A: reported with first=%s (%s)" % [first, key])
	await g.rewards.flush()
	check(reported.size() >= 1 and not m.reporter.has_pending() and reported[0][1] is Dictionary and not (reported[0][1] as Dictionary).has("error"), "A: batch sent through the party session, backend answered, nothing pending")
	check(g.director.enemies.size() <= adds_before, "A: its adds leave with it")
	return shards


## The rite world sees the boss, a rite (Bone Needle) hits it, a stun staggers it at most 0.5 s and has a cooldown. (The thralls' engage / credit rules are
## the framework's, checked once in the Gravedigger's part.)
func check_rites_and_stun() -> void:
	var caster: DmRiteCaster = hb.get_node("Rites")
	put(arena() + Vector3(-5.0, 0.0, 2.0))
	step(DT)   # the body's hp mirrors the brain's after a tick
	check(g.enemies_in_radius(boss.global_position, 0.5).has(boss) and g.enemy_by_id(int(boss.get_meta(&"dm_id"))) == boss, "A: the rite world sees the boss (enemies_in_radius / enemy_by_id)")
	var hp_r := boss.hp
	caster.request_cast("bone_needle", boss.global_position, int(boss.get_meta(&"dm_id")))
	await until(func() -> bool: return boss.hp < hp_r, 3.0)
	check(boss.hp < hp_r, "A: Bone Needle damages the boss (%.1f)" % (hp_r - boss.hp))
	_keep(hb)
	boss.stun(5.0)
	check(boss.brain.stagger_t > 0.0 and boss.brain.stagger_t <= DmBoss.STUN_CAP_S, "A: a stun staggers the boss at most 0.5 s")
	var st0: float = boss.brain.stagger_t
	boss.stun(5.0)
	check(is_equal_approx(boss.brain.stagger_t, st0), "A: stun has a cooldown (no stun-lock)")


## Wipe: the hero leaves the area, the boss resets (no reward) and can be woken again.
func check_wipe() -> void:
	var resets: Array = []
	g.bosses.reset.connect(func(id: String) -> void: resets.append(id))
	var earned0 := int(member().stats["bosses"])
	hb.teleport(Vector3(0, 0, 20))
	g.bosses.assume_area = ""
	boss.world.refresh()
	step(0.1)
	check(resets == [boss_id] and not boss.is_hittable() and boss.sm.id() != DmEnemyState.Id.DEAD, "A: everyone gone -> the boss resets (can be woken again)")
	check(int(member().stats["bosses"]) == earned0, "A: a reset pays nothing")


## After a kill: the boss is freed and woken again at its site (the shards for it granted), then a wipe resets it, then it is freed again.
func check_rewake_and_wipe() -> void:
	await end_fight()
	await at_site(int(def()["shards"]))
	check(wake() == "", "A: woken again after the kill")
	check_wipe()
	await end_fight()


## The woken boss fights on the real engine clock for `secs` (with whatever `extra` sets up: pools, corpses, adds): it ticks and logs events. No timing
## is asserted; an engine error in the long run lands in the log check.
func check_engine_run(secs: float, extra: Callable = Callable()) -> void:
	g.bosses.assume_area = area()
	put(arena() + Vector3(3.0, 0.0, 0.0))
	if extra.is_valid():
		extra.call()
	var n0 := evs.size()
	boss.set_physics_process(true)
	await ticks(int(secs * 60.0))
	boss.set_physics_process(false)
	check(boss.bstate.active and evs.size() > n0, "A: the engine-driven boss ticks and fights (%d events in %.0f s)" % [evs.size() - n0, secs])


## THE crowd perf probe (report-only, run once for the whole suite on the live boss `boss`): brain tick cost, whole physics frame with the boss brain ticking
## vs not over 20 adds + 6 thralls + corpses, and an fx burst. Tests never assert wall-clock time, so the figures print as INFO.
func check_perf_once() -> void:
	_keep(hb)
	g.director.enabled = false
	var a := arena()
	for i in 20:
		g.director.spawn("ghoul" if i % 2 == 0 else "robber", a + Vector3(sin(float(i)) * 8.0, 0.0, cos(float(i)) * 8.0), [hb])
	var th: DmThrallHost = hb.get_node("Thralls")
	th.clear()
	check(bool(th.raise_bonded({"kind": "warrior", "cap": 6.0, "hp": 9000.0, "damage": 5.0, "attackSpeedMult": 1.0})["ok"]), "C: bonded thrall")
	for i in 5:
		g.corpses.add_corpse(a.x - 4.0 + float(i), a.z + 2.0, "normal", "robber", false, 0.0, 1.0, area())
		th.raise({"kind": "warrior", "cap": 99.0, "hp": 9000.0, "damage": 5.0, "attackSpeedMult": 1.0}, Vector3(a.x - 4.0 + float(i), 0.0, a.z + 2.0))
	await ticks(30)
	boss.set_physics_process(false)
	boss.world.refresh()
	var samples: Array = []
	for i in 400:
		var u0 := Time.get_ticks_usec()
		boss._physics_process(DT)
		samples.append(Time.get_ticks_usec() - u0)
	samples.sort()
	var med: float = samples[samples.size() / 2]
	print("perf: boss brain tick median %.0f us, p95 %.0f us (20 adds, %d thralls)" % [med, samples[int(samples.size() * 0.95)], th.count()])
	check(th.count() == 6, "C: 6 thralls standing")
	perf_info(med < 400.0, "C: boss tick median %.0f us < 400 us (budget)" % med)
	# whole physics frame with the boss ticking vs not (everything else - 20 adds, 6 thralls, hero, session - identical)
	var offs: Array = []
	var ons: Array = []
	for round_ in 6:   # interleaved blocks: the shared VPS drifts
		boss.set_physics_process(false)
		offs.append(await _frame_median(40))
		boss.set_physics_process(true)
		ons.append(await _frame_median(40))
	boss.set_physics_process(false)
	offs.sort()
	ons.sort()
	var med_off: float = offs[0]   # the quietest block of each: a block the OS descheduled on a loaded VPS inflates one side only
	var med_on: float = ons[0]
	print("perf: physics frame median %.2f ms without the boss brain, %.2f ms with it (delta %.2f ms)" % [med_off, med_on, med_on - med_off])
	perf_info(med_on - med_off < 2.0, "C: the boss brain adds < 2 ms per physics frame (%.2f ms)" % (med_on - med_off))
	# an event burst: the fx for a telegraph + impact
	var fx_us := 0
	for i in 50:
		var u1 := Time.get_ticks_usec()
		g.bosses.fx.play({"t": "boss", "kind": "sweep", "x": a.x, "z": a.z, "phase": 1, "boss": boss_id, "ms": 900.0, "dir": 0.5, "r": 4.5})
		fx_us += Time.get_ticks_usec() - u1
	print("perf: sweep telegraph fx %.0f us/event" % (float(fx_us) / 50.0))
	perf_info(float(fx_us) / 50.0 < 2000.0, "C: telegraph fx < 2 ms per event")
	th.clear()
	clear_adds()
	g.director.enabled = g_director_on


func _frame_median(n: int) -> float:
	var frames: Array = []
	for i in n:
		await physics_frame
		frames.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	frames.sort()
	return frames[frames.size() / 2]


# ---- two peers (B): ONE host + client pair for the whole suite; each boss is summoned on it in turn -------------------------------------------

## The pair, booted on the first call: a host and a client over ENet on a free port.
func net_up() -> void:
	if hg != null and is_instance_valid(hg):
		return
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	hg = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	cg = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(PORT, 4) == OK, "B: ENet server on a free port")
	await hg.start(character, api, {"peer": sp, "dressing": false, "hud": false, "waves": false, "audio": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", PORT)
	await cg.start(character, api, {"peer": cp, "host": false, "world": false, "hud": false, "audio": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "B: client joined")


func net_down() -> void:
	if hg != null and is_instance_valid(hg):
		hg.queue_free()
	if cg != null and is_instance_valid(cg):
		cg.queue_free()
	hg = null
	cg = null
	await ticks(3)


## The boss is summoned on the host with the host's hero at its site; `cboss` is the client's puppet. Fresh counting stubs for this boss.
func two_peers_summon() -> void:
	await net_up()
	hstub = Stub.new()
	cstub = Stub.new()
	hast = Stub.new()
	cast_ = Stub.new()
	hg.bosses.fx.set_backends(hstub, hast)
	cg.bosses.fx.set_backends(cstub, cast_)
	hg.enemy_fx.set_backends(hstub, hast)
	cg.enemy_fx.set_backends(cstub, cast_)
	var hh := hg.local_body()
	if god_mode:
		god(hh)
	hg.bosses.assume_area = area()
	hh.teleport(site() + Vector3(0.0, 0.0, 2.0))
	await ticks(3)
	var hm: DmRewardsMember = hg.rewards.members[int(character.get("id", 0))]
	hm.prog.local["shards"] = int(def()["shards"])
	check(hg.bosses.try_summon(hg.session.get_my_id(), boss_id) == "", "B: host summons")
	hboss = hg.bosses.active_boss()
	hboss.set_physics_process(false)
	var bid := int(hboss.get_meta(&"dm_id"))
	check(await until(func() -> bool: return cg.bosses.boss_by_id(bid) != null and cg.bosses.boss_by_id(bid).is_inside_tree(), 6.0), "B: the boss body spawns on the client (same dm_id)")
	cboss = cg.bosses.boss_by_id(bid)
	check(cboss != null and not cboss.is_multiplayer_authority() and cboss.brain == null and cboss.boss_id == boss_id, "B: client body is a brainless puppet")
	check(await until(func() -> bool: return cboss.bstate.active and absf(cboss.max_hp - hboss.max_hp) < 0.01, 4.0), "B: state replicates (active, max hp)")
	hh.teleport(arena() + Vector3(3.0, 0.0, 0.0))
	hboss.world.refresh()


## One host-side brain tick with the host's hero kept alive.
func nstep(n: int = 1) -> void:
	var hh := hg.local_body()
	for i in n:
		_keep(hh)
		hboss._physics_process(DT)


## This boss is done on the pair: the host's body goes and the client's puppet follows through the replication (the next boss is summoned on the same pair).
func two_peers_end() -> void:
	var puppet_id := cboss.get_instance_id()
	if hboss != null and is_instance_valid(hboss):
		hboss.queue_free()
	hg.bosses.assume_area = ""
	hg.local_body().teleport(Vector3(0, 0, 20))
	await until(func() -> bool: return not is_instance_id_valid(puppet_id), 3.0)
	for peer: DmNextGame in [hg, cg]:   # the pools (visual only on the client) of this boss
		var pools := peer.bosses.get_node_or_null("Pools")
		if pools != null:
			for z in pools.get_children():
				z.free()
	await ticks(3)
	hboss = null
	cboss = null


## B's generic replication (run once, for one boss): events once per peer, the awaken sound once on each, the telegraph decals, phase + hp + position.
func two_peers_replication() -> void:
	var hh := hg.local_body()
	check(await until(func() -> bool: return cstub.calls.get("decal", 0) > 0, 3.0), "B: the client played the telegraph decals")
	check(await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events, 3.0), "B: every event is played exactly once per peer (host %d, client %d)" % [hg.bosses.fx.events, cg.bosses.fx.events])
	check(hast.sfx.count("bossAwaken") == 1 and await until(func() -> bool: return cast_.sfx.count("bossAwaken") == 1, 2.0), "B: the awaken sound plays once on each peer")
	hboss.take_damage(hboss.hp - hboss.max_hp * 0.55, hh)
	nstep(10)
	check(await until(func() -> bool: return cboss.phase == 2 and absf(cboss.hp - hboss.hp) < hboss.max_hp * 0.01, 3.0), "B: phase and hp replicate (client phase %d, hp %.0f / %.0f)" % [cboss.phase, cboss.hp, hboss.hp])
	check(await until(func() -> bool: return cg.bosses.fx.events == hg.bosses.fx.events, 2.0), "B: the phase event reached the client once")
	check(cboss.global_position.distance_to(hboss.global_position) < 2.5, "B: the client's boss follows the host's position")


## B's tail for every boss: the client sees the boss die and plays the defeat sound.
func two_peers_defeat() -> void:
	hboss.take_damage(hboss.hp + 1.0, hg.local_body())
	check(await until(func() -> bool: return cboss.sm.id() == DmEnemyState.Id.DEAD, 3.0), "B: the client sees the boss die")
	check(await until(func() -> bool: return cast_.sfx.has("bossDefeat"), 3.0), "B: the defeat sound plays on the client too")


## The first telegraph of a boss replicates: steps the host brain until something is pending, the client sees it with the kind (`first_attack`).
func two_peers_first_telegraph(first_attack: String) -> void:
	for i in 200:
		nstep()
		if not hboss.brain.pending.is_empty():
			break
	check(await until(func() -> bool: return cboss.telegraphs.size() >= 1, 3.0), "B: the client sees a telegraph in the replicated state (%s)" % (String(cboss.telegraphs[0][0]) if cboss.telegraphs.size() > 0 else "-"))
	if cboss.telegraphs.size() > 0:
		check(String(cboss.telegraphs[0][0]) == first_attack, "B: telegraph kind replicates (%s)" % first_attack)


## A pool-throwing boss: the host's pools damage, the client's are visual only, same kind and place.
func two_peers_pools(pool_kind: StringName) -> void:
	for i in 400:
		nstep()
		if get_nodes_in_group(&"dm_hostile_zone").size() > 0 and hg.bosses.get_node_or_null("Pools") != null and hg.bosses.get_node("Pools").get_child_count() > 0:
			break
	var hz := hg.bosses.get_node("Pools").get_children()
	check(hz.size() > 0 and (hz[0] as DmHostileZone).damaging, "B: the host's pools damage")
	check(await until(func() -> bool: return cg.bosses.get_node_or_null("Pools") != null and cg.bosses.get_node("Pools").get_child_count() >= hz.size(), 3.0), "B: the client got the pools (%d)" % hz.size())
	var cz := cg.bosses.get_node("Pools").get_children()
	check(cz.size() > 0 and not (cz[0] as DmHostileZone).damaging and (cz[0] as DmHostileZone).kind == pool_kind and (cz[0] as DmHostileZone).global_position.is_equal_approx((hz[0] as DmHostileZone).global_position), "B: the client's pool is visual only, same kind and place")


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
