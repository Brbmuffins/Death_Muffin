extends SceneTree
## The counsel and the first hour on the combat core (client/README.md "Tips and onboarding"): the game scene as a player gets it
## (the whole world but the Depths, today's HUD and panels, a new Gravecaller at level 1), headless. Checked:
##   - the counsel's host side (DmNextCounsel) asks the core for its facts: three living dead within 9 m of the hero make a fight (by the distance of their centres; a rising body counts, a dead
##     one does not), the corpses within 7 m, a pack of three on a corpse, the thralls he owns; against a brute-force reading of the core's tables over seeded random placements, the boundary
##     cases by hand, the busy flags (combat, hurt, dead, the boss awake) and the poll's keys;
##   - every fact the creatures give the counsel reaches it once, as today's code raises it: a spawn within 40 m (`enemy_spawned` with its def, elite flag and whether the area is safe), a corpse
##     laid (`corpse_near` with its distance), a Deacon's Sanctify (`sanctify_near`), the hero hurt (`tip` hurt below half health, `hurt_check` each blow), a cast refused for essence;
##   - each of those makes the tips today's table gives it (DmCounselEvents), each tip once: queued, shown and remembered, never twice, until "Show tips again";
##   - the state-driven tips (thrall, litany, burst, codex, wave, prelate, belt, tool) fire from the 400 ms poll on the facts of the core and the bag;
##   - the first hour: `world_entered` once as the game opens (the welcome tip, no signature or grimoire tip at level 1), the Next-step box, the Prior's greeting and advice from the live
##     guidance state, the HUD's progressive reveal, the first entry of an area, "Show tips again" and "Don't show tips";
##   - the auto cast's fact (`auto_combat_cast`), the gather bests kept in the store, GM mode (the Settings toggle, F9 break seals) for a dev account and never for a normal one;
##   - the counsel's pickup fact (`collected`), and the poll's state facts following the progression (shards, Ashes);
##   - no node per creature (the node count does not move with the crowd or the polls) and ZERO script errors or engine errors in the log.
## Gets the robber and the hound into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --fixed-fps 60 --path client --script res://tests/counsel.gd  (--fixed-fps 60 runs the 400 ms polls and the tips' seconds as fast as the CPU allows)

class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://counsel_test"
const BAKE := ["grave_robber", "bone_hound"]
const TICK_KEYS := ["wave_affordable", "thralls_mine", "corpses_near", "pack_on_corpse", "family", "level", "total_kills", "has_tool", "has_belt_item", "shards", "boss_near", "has_seal",
	"area", "cheapest_unlock", "boss_kills", "ascension", "ashes", "gate_near", "altar"]
const THRALL := {"kind": "warrior", "hp": 40.0, "maxHp": 40.0, "damage": 1.0, "attackInterval": 1.0, "range": 1.3, "speed": 5.6, "empowered": false, "champion": false, "allyHeal": 0.0}

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var h: DmNextUiHost
var ui: DmGameUi
var counsel: DmCounsel
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var events: Array = []            ## [id, ctx] of the UI host's game events, from the first one
var shown_n: Dictionary = {}      ## tip id -> how many cards were shown
var orig_max_hp := 0.0
var rng := RandomNumberGenerator.new()


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL counsel: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_ticks: int) -> bool:
	var end := Engine.get_physics_frames() + limit_ticks
	while not bool(cond.call()) and Engine.get_physics_frames() < end:
		await physics_frame
	return bool(cond.call())


func nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


## The tip is on its way or done: waiting out its delay, queued, on the screen or remembered.
func fired(tip: String) -> bool:
	return counsel.seen.has(tip) or counsel._queued(tip) or counsel.pending.has(tip) or String(counsel.shown.get("id", "")) == tip


## The game events of one id raised since `mark`.
func since(mark: int, id: String) -> Array:
	var out: Array = []
	for i in range(mark, events.size()):
		if events[i][0] == id:
			out.append(events[i][1])
	return out


func queued_n(tip: String) -> int:
	var n := 0
	for e in counsel.queue:
		if e["id"] == tip:
			n += 1
	return n


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DmUiConfig.dir = ""   # in-memory stores: the run reads and leaves nothing in the user folder, and every tip is new
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
	DmSimData.ensure()
	rng.seed = 20261017
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("counsel%d" % (Time.get_ticks_usec() % 100000), "c@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	g.child_entered_tree.connect(func(n: Node) -> void:   # the adapter's first event (world_entered) comes before start() returns
		if n is DmNextUiHost:
			(n as DmNextUiHost).game_event.connect(func(id: String, ctx: Dictionary) -> void: events.append([id, ctx])))
	root.add_child(g)
	await g.start(ch.data, api, {"name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "persist": false, "baked_dir": OUT})
	h = g.ui_host
	ui = g.ui
	counsel = ui.counsel
	counsel.record = true
	host = g.core_host
	core = host.core
	hero = g.local_body()
	counsel.card_shown.connect(func(id: String, _k: String, _t: String, _b: String, _ms: int) -> void: shown_n[id] = int(shown_n.get(id, 0)) + 1)
	await _the_port()
	await _first_hour()
	await _spawn_facts()
	await _corpse_and_sanctify_facts()
	await _hurt_and_essence_facts()
	await _the_facts_against_a_brute_force_reading()
	await _busy()
	await _state_tips()
	await _areas_and_reveal()
	await _tips_again_and_off()
	await _collected_fact()
	for id: String in shown_n:
		if id != "minimap" and id != "belt" and id != "codex" and id != "atlas" and id != "grimoire":   # the replay shows those again by design
			check(int(shown_n[id]) == 1, "tip %s was shown once (%d)" % [id, int(shown_n[id])])
	await _auto_cast_fact()
	await _gather_bests()
	await _gm_mode()
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d: %s)" % [errlog.errors.size(), str(errlog.errors.slice(0, 3))])
	print("%s counsel %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	g.queue_free()
	await process_frame
	quit(1 if fails > 0 else 0)


func _immortal(on: bool) -> void:
	if on:
		orig_max_hp = float(hero.p["stats"]["maxHp"])
		hero.p["stats"]["maxHp"] = 1.0e9
		hero.p["hp"] = 1.0e9
		hero._mirror_from_state()
	else:
		hero.p["stats"]["maxHp"] = orig_max_hp
		hero.restore_vitals()


func _clear() -> void:
	for id in core.enemy_ids():
		if host.enemy_alive(id):
			host.remove_enemy(id)
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "expired")
	for id in core.thralls_in_radius(Vector2(hero.position.x, hero.position.z), 500.0, hero.core_id):
		core.kill_thrall(id, "crumbled")


func _spawn(def: String, off: Vector3, elite := false, rising := true, area := "graves") -> int:
	return host.spawn_enemy(def, hero.position + off, 1, 1.0, 1.0, elite, area, rising)


func _hero_at() -> Vector2:
	return Vector2(hero.position.x, hero.position.z)


# ------------------------------------------------------------------------------------------------------------------ the port

func _the_port() -> void:
	check(h.counsel is DmNextCounsel and h.counsel.host == h, "the adapter's counsel is the ported DmNextCounsel")
	var ctx := h.counsel_tick_ctx()
	var missing: Array = TICK_KEYS.filter(func(k: String) -> bool: return not ctx.has(k))
	check(missing.is_empty() and ctx.size() == TICK_KEYS.size(), "the poll answers every key of today's (%d; missing %s)" % [ctx.size(), str(missing)])
	check(ctx["family"] == "necromancer" and int(ctx["level"]) == 1 and ctx["area"] == "chapterhouse" and ctx["thralls_mine"] == 0 and ctx["corpses_near"] == 0 and not ctx["pack_on_corpse"],
		"a new Gravecaller in the Chapterhouse: nothing near him, no thralls (%s)" % str(ctx))
	check(int(ctx["shards"]) == int(h.prog.local["shards"]) and int(ctx["ashes"]) == int(h.prog.local["ashes"]) and ctx["has_belt_item"] == h.inventory.slots.any(func(r: Dictionary) -> bool: return DmContent.healing_flasks().has(String(r["item_id"]))),
		"the poll carries the rebuild's state: flasks in the bag, shards, Ashes")
	check(float(ctx["cheapest_unlock"]) < INF and ctx["gate_near"] == false and ctx["boss_near"].is_empty(), "the cheapest unlock is known, and no gate or boss is near the hub")
	var busy := h.counsel_busy()
	check(not busy["combat"] and not busy["hurt"] and not busy["dead"], "and no fight")
	check(ui.counsel_busy()["area"] == "chapterhouse" and ui.counsel_busy()["safe"], "the panel host adds the area and that it is safe")
	# no node per creature: 90 bodies and 40 polls add no node
	await ticks(90)   # (the scene settles first: loading leaves a few nodes to go)
	var n0 := nodes()
	for i in 90:
		_spawn("robber", Vector3(float(i % 10) - 5.0, 0.0, 12.0 + float(i / 10)), false, true, "chapterhouse")
	for i in 40:
		h.counsel_tick_ctx()
	await ticks(2)
	check(nodes() == n0, "the node count does not move with 90 bodies in the core and 40 polls (%d -> %d)" % [n0, nodes()])
	_clear()
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ the first hour

func _first_hour() -> void:
	var entered := events.filter(func(e: Array) -> bool: return e[0] == "world_entered")
	check(entered.size() == 1, "world_entered once as the game opens (%d)" % entered.size())
	var grim := false
	var kit: Dictionary = h.kit
	var rl := DmAbilities.rite_level(1.0, h.dev_access)
	for id in kit["grimoire"]:
		if DmAbilities.unlock_level(id) <= rl and DmAbilities.unlock_level(id) > 1:
			grim = true
	check(entered.size() == 1 and entered[0][1] == {"family": "necromancer", "level": 1, "grimoire_unlocked": grim} and not grim, "...with today's facts: family, level 1, no Grimoire yet (%s)" % str(entered[0][1] if not entered.is_empty() else {}))
	check(fired("welcome"), "the welcome tip is on its way")
	check(not fired("signature") and not fired("grimoire"), "no signature or Grimoire tip at level 1")
	# a place tip (the data says the Acre): held while he stands in the Chapterhouse, shown when he walks into the Acre
	await ticks(60 * 8)
	check(fired("welcome") and not counsel.seen.has("welcome") and String(counsel.shown.get("id", "")) != "welcome", "the welcome card waits: its place is the Acre, and he stands in the Chapterhouse")
	hero.teleport(_area_mid("acre"))
	check(await until(func() -> bool: return g.area_id == "acre", 120), "he walks into the Acre")
	# (the first card a new hero sees is the belt's, from the bag's flask: 33 s on the screen, then 20 s of quiet)
	var shown_welcome := await until(func() -> bool: return counsel.seen.has("welcome") or String(counsel.shown.get("id", "")) == "welcome", 60 * 100)
	if not shown_welcome:
		print("INFO welcome held: busy ", ui.counsel_busy(), " queue ", counsel.queue.map(func(e: Dictionary) -> String: return e["id"]), " now ", counsel.now_ms, " last_closed ", counsel.last_closed_at, " enabled ", counsel.tips_enabled)
	check(shown_welcome and counsel.seen.has("acre"), "the welcome card is shown in the Acre (and the Acre's own tip counts as seen with it)")
	hero.teleport(Vector3(float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["x"]), 0.0, float(DmContent.get_export("areas", "CHAPTERHOUSE_RETURN")["z"])))
	await until(func() -> bool: return g.area_id == "chapterhouse", 120)
	# the Next-step box
	await ticks(40)
	var vm := ui.merged_vm()
	check(ui.guidance_hud.current != null and vm["next"] != null and String(vm["next"]) != "", "the Next-step box has a suggestion for a new hero (%s)" % str(vm["next"]))
	check(ui.last_guidance["level"] == 1 and ui.last_guidance["area"] == "chapterhouse" and ui.last_guidance["totalKills"] == 0 and ui.last_guidance["bagSize"] == 48, "...from the live state (%s)" % str(ui.last_guidance["area"]))
	# the Prior's words
	h.npc_interact.emit("prior")
	check(ui.dialogue.is_open() and ui.dialogue.npc == "prior" and not ui.dialogue.lines.is_empty(), "the Prior greets him (%d lines)" % ui.dialogue.lines.size())
	ui.dialogue.go("advice")
	var want: Array = DmDialogueLines.advice_lines("prior", ui.guidance_state())
	check(ui.dialogue.lines == want and not want.is_empty(), "his advice is the guidance state's, word for word")
	check(ui.counsel_busy()["talking"], "and the counsel holds its calm cards while he talks")
	ui.dialogue.close()
	# the HUD's progressive reveal: the upgrades box waits for the first gold outside a safe place
	check(not ui.reveal.has("hud.upgrades"), "the upgrades box is not revealed yet")
	# a fresh hero: the shards, the skills and the dial are held back, and show as you progress (flagged NEW until their panel is opened)
	check(not ui.reveal.has("hud.shards") and not ui.reveal.has("menu.skills") and not ui.reveal.has("hud.dial"), "fresh character: shards / skills / dial are held back")
	var held: Dictionary = ui.merged_vm()["reveal"]
	check(held.get("hud.shards") == false and held.get("menu.skills") == false, "the HUD view model holds them back")
	var skills0: Variant = ui.skills
	var shards0: Variant = h.prog.local["shards"]
	var tier0: Variant = h.prog.local["waveTierOwned"]
	h.prog.local["shards"] = 3
	ui.skills = {"mining": 2}
	h.prog.local["waveTierOwned"] = 1
	ui._progressive_tick()
	check(ui.reveal.has("hud.shards") and ui.reveal.has("menu.skills") and ui.reveal.has("hud.dial"), "shards, skills and the dial reveal as you progress")
	var rvm: Dictionary = ui.merged_vm()
	check(rvm["new"].get("menu.skills") == true and not (rvm["reveal"] as Dictionary).has("menu.skills"), "menu.skills is NEW and no longer held back")
	check(ui.pa.acre_win != null and ui.reveal.is_new("menu.skills"), "NEW pip flagged (persisted reveal)")
	ui.toggle_panel("professions")
	await ticks(3)
	check(not ui.reveal.is_new("menu.skills") and not ui.merged_vm()["new"].has("menu.skills"), "opening the panel clears the NEW pip")
	ui.close_panels()
	h.prog.local["shards"] = shards0
	h.prog.local["waveTierOwned"] = tier0
	ui.skills = skills0


# ------------------------------------------------------------------------------------------------------------------ spawns

func _spawn_facts() -> void:
	# a body that rises in the Chapterhouse (a safe place): the fact is raised with area_safe, and the table gives no tip for it
	var m := events.size()
	_spawn("robber", Vector3(3.0, 0.0, 2.0), false, true, "chapterhouse")
	await ticks(2)
	var ev := since(m, "enemy_spawned")
	check(ev.size() == 1 and ev[0] == {"def": "robber", "elite": false, "near": true, "area_safe": true}, "a robber rising in the Chapterhouse: enemy_spawned, in a safe area (%s)" % str(ev))
	check(DmCounselEvents.calls("enemy_spawned", ev[0]).is_empty() if ev.size() == 1 else false, "...for which the table gives no tip")
	_clear()
	hero.teleport(Vector3(0.0, 0.0, -10.0))   # the Graves' middle
	await until(func() -> bool: return g.area_id == "graves", 120)
	check(g.area_id == "graves", "the hero is in the Hollow Graves")
	await ticks(30)
	_immortal(true)
	m = events.size()
	_spawn("robber", Vector3(10.0, 0.0, 0.0))
	await ticks(2)
	ev = since(m, "enemy_spawned")
	check(ev.size() == 1 and ev[0] == {"def": "robber", "elite": false, "near": true, "area_safe": false}, "a robber rising 10 m away in the Graves: one enemy_spawned (%s)" % str(ev))
	check(fired("move"), "...and the move lesson is queued")
	var moves := queued_n("move") + (1 if String(counsel.shown.get("id", "")) == "move" else 0)
	m = events.size()
	_spawn("robber", Vector3(-10.0, 0.0, 0.0))
	_spawn("hound", Vector3(0.0, 0.0, 12.0))
	await ticks(2)
	check(since(m, "enemy_spawned").size() == 2, "two more bodies: two more facts")
	check(queued_n("move") + (1 if String(counsel.shown.get("id", "")) == "move" else 0) <= maxi(moves, 1), "the move lesson is still one tip, not three")
	m = events.size()
	_spawn("moth", Vector3(5.0, 0.0, 5.0))
	await ticks(2)
	ev = since(m, "enemy_spawned")
	check(ev.size() == 1 and ev[0]["def"] == "moth" and fired("moth"), "a moth: its first-sight tip (moth)")
	m = events.size()
	_spawn("robber", Vector3(-8.0, 0.0, 8.0), true)
	await ticks(2)
	ev = since(m, "enemy_spawned")
	check(ev.size() == 1 and ev[0]["elite"] == true and fired("elite"), "an elite: the elite tip")
	m = events.size()
	_spawn("deacon", Vector3(8.0, 0.0, -8.0), false, true, "ossuary")
	await ticks(2)
	ev = since(m, "enemy_spawned")
	check(ev.size() == 1 and ev[0]["def"] == "deacon" and fired("deacon"), "a Deacon: the deacon tip")
	m = events.size()
	_spawn("robber", Vector3(41.0, 0.0, 0.0))
	await ticks(2)
	check(since(m, "enemy_spawned").is_empty(), "a body 41 m away is no fact (the counsel hears of those within 40 m)")
	m = events.size()
	var far := _spawn("ghoul", Vector3(39.0, 0.0, 0.0))
	await ticks(2)
	ev = since(m, "enemy_spawned")
	check(far > 0 and ev.size() == 1 and ev[0]["def"] == "ghoul", "...and one 39 m away is")
	_clear()
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ corpses and the Sanctify

func _corpse_and_sanctify_facts() -> void:
	var m := events.size()
	var id := _spawn("robber", Vector3(5.0, 0.0, 0.0), false, false)
	await ticks(2)
	host.damage(id, 1.0e9, hero.core_id, false)
	await ticks(2)
	var ev := since(m, "corpse_near")
	check(ev.size() == 1 and ev[0]["area_safe"] == false and absf(float(ev[0]["dist"]) - 5.0) < 0.6, "a robber falls 5 m away: one corpse_near, in a fighting area, at its distance (%s)" % str(ev))
	check(fired("exhume"), "...and the Exhume tip follows")
	m = events.size()
	core.corpse_add(Vector2(hero.position.x + 20.0, hero.position.z), "normal", "robber", false, 0.0, 1.0, "graves")
	await ticks(2)
	ev = since(m, "corpse_near")
	check(ev.size() == 1 and absf(float(ev[0]["dist"]) - 20.0) < 0.01 and DmCounselEvents.calls("corpse_near", ev[0]).is_empty(), "a corpse 20 m away is a fact with its distance, and no tip (the table wants 12 m)")
	_clear()
	await ticks(2)
	# a Deacon blesses a wounded ally: the cue, and the counsel hears of it once
	m = events.size()
	var deacon := _spawn("deacon", Vector3(8.0, 0.0, 0.0), false, false, "ossuary")
	var golem := _spawn("golem", Vector3(11.0, 0.0, 0.0), false, false, "ossuary")
	var cues: Array = []
	host.cue.connect(func(_i: int, kind: int, _x: float, _z: float, _r: float) -> void: cues.append(DmCoreEvents.CUES[kind]))
	await ticks(72)
	host.damage(golem, float(host.enemy_info(golem)["max_hp"]) * 0.5, 0, false)
	check(await until(func() -> bool: return cues.has(&"sanctify"), 60 * 16), "the Deacon blesses the wounded golem (a sanctify cue)")
	await ticks(2)
	ev = since(m, "sanctify_near")
	check(deacon > 0 and ev.size() == cues.count(&"sanctify") and ev.size() >= 1 and float(ev[0]["dist"]) < 18.0, "one sanctify_near for each cue, with the blessed one's distance (%s)" % str(ev))
	check(fired("sanctify"), "...and the Sanctify tip")
	_clear()
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ the hero hurt, a cast refused

func _hurt_and_essence_facts() -> void:
	_immortal(false)
	await ticks(2)
	var m := events.size()
	hero.take_damage(hero.max_hp * 0.2)
	await ticks(2)
	check(since(m, "hurt_check").size() == 1 and since(m, "tip").is_empty() and not fired("hurt"), "a blow that leaves him above half: hurt_check, no tip")
	var hc := since(m, "hurt_check")
	check(hc.size() == 1 and absf(float(hc[0]["hp"]) - hero.hp) < 1.0 and absf(float(hc[0]["max_hp"]) - hero.max_hp) < 0.01, "...with his health")
	hero.take_damage(hero.max_hp * 0.4)
	await ticks(2)
	check(since(m, "hurt_check").size() == 2 and since(m, "tip").size() == 1 and since(m, "tip")[0]["id"] == "hurt" and fired("hurt"), "below half: the hurt tip, once")
	check(h.counsel_busy()["hurt"] and h.counsel_busy()["combat"], "and the counsel is held: hurt, in combat")
	hero.restore_vitals()
	# a cast with no essence
	var caster := hero.get_node("Rites") as DmRiteCaster
	caster.p["resource"]["value"] = 0.0
	caster.p["castUntil"] = 0.0
	m = events.size()
	caster.request_cast("marrow_spear", hero.position + Vector3(4.0, 0.0, 0.0), -1)
	await ticks(2)
	check(since(m, "essence_short").size() == 1 and fired("essence"), "a cast refused for essence: essence_short, and the essence tip")
	hero.restore_vitals()
	_immortal(true)


# ------------------------------------------------------------------------------------------------------------------ the facts, read two ways

## Today's code over the core's tables: the living dead are the non-dead bodies by the distance of their centres.
func _living_within(at: Vector2, r: float, ids: PackedInt32Array, pos: PackedFloat32Array, states: PackedInt32Array) -> int:
	var n := 0
	for i in ids.size():
		if states[i] != DmCoreEvents.State.DEAD and Vector2(pos[i * 3], pos[i * 3 + 1]).distance_to(at) < r:
			n += 1
	return n


func _the_facts_against_a_brute_force_reading() -> void:
	var hp := _hero_at()
	var worst := ""
	var combats := 0
	var packs := 0
	var trials := 24
	for trial in trials:
		_clear()
		var n := rng.randi_range(0, 7)
		for i in n:
			var a := rng.randf() * TAU
			var r := rng.randf() * 13.0
			_spawn("robber", Vector3(cos(a) * r, 0.0, sin(a) * r))
		var corpses: Array = []
		for i in rng.randi_range(0, 5):
			var a2 := rng.randf() * TAU
			var r2 := rng.randf() * 10.0
			var cp := Vector2(hp.x + cos(a2) * r2, hp.y + sin(a2) * r2)
			core.corpse_add(cp, "normal", "robber", false, 0.0, 1.0, "graves")
			corpses.append(cp)
			if rng.randf() < 0.6:   # a pack on this corpse
				for k in rng.randi_range(1, 4):
					var a3 := rng.randf() * TAU
					var r3 := rng.randf() * 4.0
					host.spawn_enemy("robber", Vector3(cp.x + cos(a3) * r3, 0.0, cp.y + sin(a3) * r3), 1, 1.0, 1.0, false, "graves", true)
		if rng.randf() < 0.3:   # a body killed: not counted
			var dead := _spawn("robber", Vector3(2.0, 0.0, 2.0))
			host.damage(dead, 1.0e9, hero.core_id, false)
		var ids: PackedInt32Array = core.enemy_ids()
		var pos: PackedFloat32Array = core.enemy_positions()   # x, z, yaw a body
		var states: PackedInt32Array = core.enemy_states()
		var want_near := 0
		var want_pack := false
		for cid in core.corpse_ids():
			var info: Dictionary = core.corpse_info(cid)
			var cp2 := Vector2(float(info["x"]), float(info["z"]))
			if cp2.distance_to(hp) <= 7.0:
				want_near += 1
				if _living_within(cp2, 3.0, ids, pos, states) >= 3:
					want_pack = true
		var want_fight := _living_within(hp, 9.0, ids, pos, states) >= 3
		h.counsel.last_combat_ms = -1.0e9
		h.counsel.last_hurt_ms = -1.0e9
		var ctx := h.counsel_tick_ctx()
		var fight: bool = h.counsel_busy()["combat"]
		if int(ctx["corpses_near"]) != want_near or bool(ctx["pack_on_corpse"]) != want_pack or fight != want_fight:
			worst = "trial %d: corpses %d (want %d), pack %s (want %s), fight %s (want %s)" % [trial, int(ctx["corpses_near"]), want_near, str(ctx["pack_on_corpse"]), str(want_pack), str(fight), str(want_fight)]
			break
		combats += 1 if want_fight else 0
		packs += 1 if want_pack else 0
	check(worst == "", "%d seeded placements: the poll reads the core as today's code reads the nodes (%s)" % [trials, worst if worst != "" else "corpses within 7 m, a pack on a corpse, a fight: %d of them fights, %d with a pack" % [combats, packs]])
	check(combats >= 4 and packs >= 4 and combats < trials, "the placements had fights and packs in them, and quiet ones (%d fights, %d packs of %d)" % [combats, packs, trials])
	# the edges by hand: the centre decides, not the edge
	_clear()
	h.counsel.last_combat_ms = -1.0e9
	for i in 3:
		_spawn("robber", Vector3(9.3 + 0.01 * float(i), 0.0, 0.0))   # the edge within 9 m (a body is about 0.45 wide), the centre not
	h.counsel_tick_ctx()
	check(not h.counsel_busy()["combat"], "three bodies whose edges are within 9 m but whose centres are 9.3 m away are no fight")
	_clear()
	for i in 3:
		_spawn("robber", Vector3(8.7, 0.0, 0.01 * float(i)))
	h.counsel_tick_ctx()
	check(h.counsel_busy()["combat"], "three at 8.7 m are")
	_clear()
	h.counsel.last_combat_ms = -1.0e9
	for i in 2:
		_spawn("robber", Vector3(4.0, 0.0, float(i)))
	h.counsel_tick_ctx()
	check(not h.counsel_busy()["combat"], "two are not")
	var third := _spawn("robber", Vector3(4.0, 0.0, 2.0), false, false)
	host.damage(third, 1.0e9, hero.core_id, false)
	h.counsel_tick_ctx()
	check(not h.counsel_busy()["combat"], "...nor two and a dead one")
	_clear()
	# a pack at the edge of the 3 m circle, and a corpse at the edge of the 7 m one
	core.corpse_add(Vector2(hp.x + 7.0, hp.y), "normal", "robber", false, 0.0, 1.0, "graves")
	core.corpse_add(Vector2(hp.x + 7.2, hp.y), "normal", "robber", false, 0.0, 1.0, "graves")
	check(int(h.counsel_tick_ctx()["corpses_near"]) == 1, "a corpse 7.0 m away is near, one 7.2 m away is not")
	_clear()
	var cp3 := Vector2(hp.x + 5.0, hp.y)
	core.corpse_add(cp3, "normal", "robber", false, 0.0, 1.0, "graves")
	for i in 3:
		host.spawn_enemy("robber", Vector3(cp3.x + 3.2, 0.0, cp3.y + 0.1 * float(i)), 1, 1.0, 1.0, false, "graves", true)   # edges within 3 m of it, centres 3.2 m
	check(not h.counsel_tick_ctx()["pack_on_corpse"], "three bodies 3.2 m from a corpse are no pack")
	_clear()
	core.corpse_add(cp3, "normal", "robber", false, 0.0, 1.0, "graves")
	for i in 3:
		host.spawn_enemy("robber", Vector3(cp3.x + 2.8, 0.0, cp3.y + 0.1 * float(i)), 1, 1.0, 1.0, false, "graves", true)
	check(h.counsel_tick_ctx()["pack_on_corpse"], "...and at 2.8 m they are")
	_clear()
	# the cost of a poll in a crowd: 72 bodies around him and 30 corpses within 7 m, none of them a pack (the worst case: every corpse is asked)
	for i in 72:
		var a4 := float(i) * 2.399963
		var r4 := 8.0 + float(i % 6) * 0.8
		_spawn("robber", Vector3(cos(a4) * r4, 0.0, sin(a4) * r4))
	for i in 30:
		var a5 := float(i) * 2.399963
		core.corpse_add(Vector2(hp.x + cos(a5) * 6.5, hp.y + sin(a5) * 6.5), "normal", "robber", false, 0.0, 1.0, "graves")
	var t0 := Time.get_ticks_usec()
	for i in 200:
		h.counsel_tick_ctx()
	var poll_ms := float(Time.get_ticks_usec() - t0) / 200000.0
	print("INFO counsel poll: %.3f ms (72 bodies, 30 corpses near; every 400 ms)" % poll_ms)
	_clear()
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ the busy flags

func _busy() -> void:
	_clear()
	h.counsel.last_combat_ms = -1.0e9
	h.counsel.last_hurt_ms = -1.0e9
	var b := h.counsel_busy()
	check(not b["combat"] and not b["hurt"] and not b["dead"], "quiet: not busy")
	var calm := {"id": "belt", "kind": "calm", "queued_at": 45000.0, "seq": 1}
	var cad := func(busy: Dictionary) -> Dictionary: return {"now": 50000.0, "last_closed_at": 0.0, "group_shown_at": {}, "busy": busy}
	var quiet := ui.counsel_busy()
	quiet["banner"] = false   # an area's banner may be up from the walk here: it holds calm tips too, which is not what this checks
	check(DmCounselCadence.can_show(calm, cad.call(quiet)), "a calm tip may show")
	for i in 3:
		_spawn("robber", Vector3(5.0 + float(i), 0.0, 0.0))
	h.counsel_tick_ctx()
	check(h.counsel_busy()["combat"] and not h.counsel_busy()["hurt"], "three bodies near: in combat, not hurt")
	var fight := ui.counsel_busy()
	fight["banner"] = false
	check(not DmCounselCadence.can_show(calm, cad.call(fight)), "a calm tip is held back in a fight")
	check(h.in_combat(), "...and the Grimoire's rune swap says so (in_combat)")
	_clear()
	h.counsel.last_combat_ms = -1.0e9
	check(not h.in_combat(), "the flag lets go four seconds after the last fight")
	# the boss awake: combat and hurt together
	g.my_member().prog.add_shards(int(DmContent.boss("gravedigger")["shards"]) * 2)
	hero.teleport(g.bosses.site_pos("gravedigger") + Vector3(0.0, 0.0, 2.0))
	await ticks(3)
	var why := g.bosses.try_summon(g.session.get_my_id(), "gravedigger")
	check(why == "", "the King wakes (%s)" % why)
	h.counsel.last_combat_ms = -1.0e9
	h.counsel.last_hurt_ms = -1.0e9
	h.counsel_tick_ctx()
	check(h.counsel_busy()["combat"] and h.counsel_busy()["hurt"], "with the boss awake the counsel is held: combat and hurt")
	var near: Variant = h.counsel_tick_ctx()["boss_near"]
	check(near is Array and (near as Array).has("gravedigger"), "and the poll knows the hero stands at his grave (%s)" % str(near))
	var boss := g.bosses.active_boss()
	if boss != null:
		boss.queue_free()
	await ticks(10)
	check(g.bosses.active_boss() == null, "the King is gone")
	_clear()
	# a dead hero: busy.dead and no poll
	_immortal(false)
	hero.take_damage(hero.max_hp * 5.0)
	await ticks(2)
	check(not hero.alive and h.counsel_busy()["dead"] and h.counsel_tick_ctx().is_empty(), "a fallen hero: busy.dead, an empty poll")
	await until(func() -> bool: return hero.alive, 60 * 8)
	check(hero.alive and not h.counsel_busy()["dead"], "he gets up: not dead")
	hero.teleport(Vector3(0.0, 0.0, -10.0))
	await until(func() -> bool: return g.area_id == "graves", 120)
	await ticks(10)
	_immortal(true)


# ------------------------------------------------------------------------------------------------------------------ the state-driven tips

func _state_tips() -> void:
	_clear()
	await ticks(2)
	counsel.reset()   # every tip new again; the replay below counts from here
	shown_n.clear()
	h.character["level"] = 5
	h.prog.local["totalKills"] = 20
	# thralls: one stands (the thrall tip), four places and a corpse beside (the Litany tip)
	var ids: Array = []
	ids.append(int(core.raise_thrall(THRALL, hero.core_id, Vector2(hero.position.x + 2.0, hero.position.z + 3.0), 0.0, 20.0)))
	await ticks(2)
	var ctx := h.counsel_tick_ctx()
	check(int(ctx["thralls_mine"]) == 1, "one thrall stands: the poll says 1")
	check(await until(func() -> bool: return fired("thrall"), 60 * 3), "...and the thrall tip fires from the 400 ms poll")
	for i in 2:
		ids.append(int(core.raise_thrall(THRALL, hero.core_id, Vector2(hero.position.x + 3.0 + float(i), hero.position.z + 3.0), 0.0, 20.0)))
	core.corpse_add(Vector2(hero.position.x - 3.0, hero.position.z), "normal", "robber", false, 0.0, 1.0, "graves")
	await ticks(2)
	ctx = h.counsel_tick_ctx()
	check(int(ctx["thralls_mine"]) == 3 and int(ctx["corpses_near"]) == 1, "three thralls and a corpse: the poll says so (%d, %d)" % [int(ctx["thralls_mine"]), int(ctx["corpses_near"])])
	check(await until(func() -> bool: return fired("litany"), 60 * 3), "four of them at level 2 or more: the Litany tip")
	core.kill_thrall(ids[0], "killed")
	await ticks(2)
	check(int(h.counsel_tick_ctx()["thralls_mine"]) == 2, "a thrall killed: 2")
	# a pack on a corpse after 15 kills (set above to 20)
	var cp := Vector2(hero.position.x - 3.0, hero.position.z)
	for i in 3:
		host.spawn_enemy("robber", Vector3(cp.x + 1.0, 0.0, cp.y + 0.3 * float(i)), 1, 1.0, 1.0, false, "graves", true)
	await ticks(2)
	check(h.counsel_tick_ctx()["pack_on_corpse"], "three on a corpse: a pack")
	check(await until(func() -> bool: return fired("burst"), 60 * 3), "...with 15 kills behind him: the Corpse Explosion tip")
	_clear()
	await ticks(2)
	# the rest of the poll's table, one fact at a time (the calm queue holds four): kills, the bag, shards, gold
	var saved_bag: Array = h.inventory.slots.duplicate(true)
	var flask: String = String(DmContent.healing_flasks().keys()[0])
	var tool_id := ""
	for k in DmContent.items():
		if String(k).begins_with("tool_"):
			tool_id = String(k)
			break
	var cases := [
		["codex", {"kills": 41}], ["belt", {"bag": flask}], ["tool", {"bag": tool_id}], ["prelate", {"shards": int(DmCounselData.c("BOSS_SUMMON_SHARDS"))}], ["wave", {"gold": 1000000}],
	]
	for c: Array in cases:
		counsel.reset()
		_facts(c[1])
		ctx = h.counsel_tick_ctx()
		var want := DmCounselEvents.tick_calls(ctx).map(func(t: Dictionary) -> String: return String(t["tip"]))
		check(want == [c[0]], "%s: today's table gives exactly this tip for these facts (%s)" % [c[0], str(want)])
		check(await until(func() -> bool: return fired(c[0]), 60 * 3), "%s: fires from the poll" % c[0])
		await ticks(60)
		check(queued_n(c[0]) <= 1, "%s: queued at most once however many polls pass (%d)" % [c[0], queued_n(c[0])])
	_facts({})
	h.inventory.slots = saved_bag
	h.character["level"] = 1
	# the build has no Altar of Ascension (B36): the three tips that send the player there are held back, however many kills, Ashes and shards he has
	var rich := h.counsel_tick_ctx()
	check(rich["altar"] == false, "the poll says the build has no Altar")
	rich.merge({"area": "chapterhouse", "total_kills": 500, "boss_kills": 1, "ascension": 1, "ashes": 10, "shards": 100, "cheapest_unlock": 3.0}, true)
	var altar_tips := DmCounselEvents.tick_calls(rich).map(func(t: Dictionary) -> String: return String(t["tip"]))
	check(not altar_tips.has("vows") and not altar_tips.has("altar_unlocks") and not altar_tips.has("boons"), "...so with 500 kills, Ashes and shards in the Chapterhouse: no vows, altar_unlocks or boons tip (%s)" % str(altar_tips))
	rich["altar"] = true
	altar_tips = DmCounselEvents.tick_calls(rich).map(func(t: Dictionary) -> String: return String(t["tip"]))
	check(altar_tips.has("vows") and altar_tips.has("altar_unlocks") and altar_tips.has("boons"), "(and on today's facts the same ctx gives all three: %s)" % str(altar_tips))


## The poll's non-creature facts: kills, shards, gold and one item in the bag ({} = none of them).
func _facts(f: Dictionary) -> void:
	h.prog.local["totalKills"] = int(f.get("kills", 20))
	h.prog.local["shards"] = int(f.get("shards", 0))
	h.character["gold"] = int(f.get("gold", 0))
	h.inventory.slots = []   # the bag's own flask is a fact too (the belt tip)
	if f.has("bag"):
		h.inventory.slots.append({"slot_index": 40, "item_id": String(f["bag"]), "quantity": 1})


# ------------------------------------------------------------------------------------------------------------------ areas and the reveal

func _areas_and_reveal() -> void:
	# the HUD's progressive reveal: gold gained outside a safe place reveals the upgrades box
	check(not ui.area_safe() and g.area_id == "graves", "the hero stands in a fighting area")
	await ticks(40)
	h.character["gold"] = int(h.character["gold"]) + 50
	check(await until(func() -> bool: return ui.reveal.has("hud.upgrades"), 60 * 3), "the first gold outside a safe place reveals the upgrades box")
	# the first entry of an area: the fact and its tip; the second entry is nothing new
	var m := events.size()
	hero.teleport(_area_mid("cloister"))
	check(await until(func() -> bool: return g.area_id == "cloister", 120), "the hero enters the Cloister")
	await ticks(4)
	var ev := since(m, "area_first_entered")
	check(ev.size() == 1 and ev[0] == {"area": "cloister"} and fired("cloister"), "its first entry: area_first_entered once, and the Cloister tip (%s)" % str(ev))
	m = events.size()
	hero.teleport(_area_mid("graves"))
	await until(func() -> bool: return g.area_id == "graves", 120)
	hero.teleport(_area_mid("cloister"))
	await until(func() -> bool: return g.area_id == "cloister", 120)
	await ticks(4)
	check(since(m, "area_first_entered").is_empty(), "the second entry raises nothing")
	hero.teleport(Vector3(0.0, 0.0, -10.0))
	await until(func() -> bool: return g.area_id == "graves", 120)


func _area_mid(id: String) -> Vector3:
	var r: Dictionary = DmContent.area(id)["rect"]
	return Vector3((float(r["x0"]) + float(r["x1"])) * 0.5, 0.0, (float(r["z0"]) + float(r["z1"])) * 0.5)


# ------------------------------------------------------------------------------------------------------------------ Show tips again, Don't show tips

func _tips_again_and_off() -> void:
	counsel.show("codex", 0.0, {"kind": "asked"})
	check(await until(func() -> bool: return counsel.seen.has("codex"), 60 * 30), "a card is shown and remembered")
	counsel.dismiss()
	ui.set_ui.reset_tips()
	check(not counsel.seen.has("codex"), "Settings > Show tips again forgets what was seen")
	check(fired("minimap") and fired("belt") and fired("codex"), "...and walks the parts of the screen he has: the minimap, the belt, the Codex")
	check(fired("atlas") == ui.reveal.has("menu.atlas") and fired("grimoire") == ui.reveal.has("hud.spells"), "...the Atlas and the Grimoire only if they are revealed")
	shown_n.clear()
	h.counsel.last_combat_ms = -1.0e9   # (the flags run on the wall clock, four seconds, which a fast-forwarded run has not spent since the fights above)
	h.counsel.last_hurt_ms = -1.0e9
	var replayed := await until(func() -> bool: return not shown_n.is_empty(), 60 * 60)
	check(replayed, "the first replayed card is shown (%s)" % str(shown_n.keys()))
	# Don't show tips: the card goes, the queue empties, a new fact makes no tip
	ui.update_setting({"no_tips": true})
	await ticks(2)
	check(not counsel.tips_enabled and counsel.queue.is_empty() and counsel.shown.is_empty(), "Don't show tips: nothing shown, nothing queued")
	var m := events.size()
	_spawn("bat", Vector3(6.0, 0.0, 6.0))
	await ticks(2)
	check(since(m, "enemy_spawned").size() == 1 and not fired("bats"), "a new kind of body is still a fact, and makes no tip")
	ui.update_setting({"no_tips": false})
	_clear()
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ the pickup fact

func _collected_fact() -> void:
	var m := events.size()
	var member: DmRewardsMember = g.rewards.members[int(h.character["id"])]
	var gear := ""
	for id in DmContent.items():
		var meta: Dictionary = DmContent.items()[id]
		if String(meta.get("type", "")) in ["weapon", "chest_armor"] and String(meta.get("rarity", "")) == "common":
			gear = String(id)
			break
	member.loot_view.item(hero.position, {"item_id": gear, "quantity": 1}, true)
	member.loot_view.request_pickup(member.loot_view._drops[-1])   # a click on it
	await until(func() -> bool: return not since(m, "collected").is_empty(), 60 * 4)
	var ev := since(m, "collected")
	check(ev.size() == 1 and ev[0]["gear"] == true, "picking up gear emits the 'collected' counsel event once")


# ------------------------------------------------------------------------------------------------------------------ the auto cast, gather bests, GM mode

## The auto cast's fact (the creatures' facts are the core's events above).
func _auto_cast_fact() -> void:
	_clear()
	var store := h.settings_store
	store.set_active_character(int(g.character.get("id", 1)), true)
	store.update({"difficulty": "easy", "auto_combat": true})
	var m := events.size()
	var foe := host.spawn_enemy("robber", hero.position + Vector3(0, 0, -6), 1, 1000.0, 0.0, false, g.area_id, false)
	check(await until(func() -> bool: return not since(m, "auto_combat_cast").is_empty(), 60 * 8), "auto_combat_cast raised by an auto cast")
	store.update({"auto_combat": false})
	host.remove_enemy(foe)
	_clear()


## The best gather session of each skill is kept in the store under the game's key, read back after a relaunch, and replaced by a better one.
func _gather_bests() -> void:
	var skill: String = String(DmContent.get_export("gameplay_gatheringRules", "SKILLS").keys()[0])
	var item_id := String(DmContent.items().keys()[0])
	var make_session := func(qty: int) -> void:
		var gs := DmGatherSession.new(float(Time.get_ticks_msec()) - 120000.0,
			func(id: String) -> Dictionary: return {"name": id, "rarity": "common", "sell": 1},
			func(_s: String) -> int: return 1, func(_s: String) -> float: return 0.0)
		gs.record({"skill": skill, "items": [{"itemId": item_id, "qty": qty}], "xp": 40 * qty})
		g.gather.session = gs
	make_session.call(5)
	await g.gather._end_session("test")
	var key := "dm_gather_best_v1:%d" % int(h.character["id"])
	var stored: Variant = JSON.parse_string(g.progress.store.get_item(key))
	check(stored is Dictionary and int(stored[skill]["items"]) == 5, "bests are written under the current game's key")
	g.gather.bests = {}   # a relaunch: read back from the store
	var m := events.size()
	make_session.call(9)
	await g.gather._end_session("test")
	var rep: Array = since(m, "gather_report")
	check(not rep.is_empty() and ((rep.back()["report"]["records"]) as Array).size() == 1, "a better session reads the stored best (records: %s)" % [rep.back()["report"]["records"] if not rep.is_empty() else "-"])
	check(int(JSON.parse_string(g.progress.store.get_item(key))[skill]["items"]) == 9, "and stores the new best")


## GM mode: never for a normal account; for a dev account the Settings toggle opens and closes progression, gathering tiers, the host's caster and the sealed halls, and F9 breaks every seal.
func _gm_mode() -> void:
	var f9 := InputEventKey.new()
	f9.keycode = KEY_F9
	f9.pressed = true
	# a normal account
	check(not h.dev_account and not h.dev_access and not h.prog.dev_access, "normal account: dev access never on")
	h.settings_store.update({"dev_access": false})
	h.settings_store.update({"dev_access": true})
	check(not h.dev_access and not g.gather.skills.dev_access, "the toggle does nothing for a normal account")
	var unlocked0: int = h.prog.local["unlocked"].size()
	g.input._unhandled_input(f9)
	check(h.prog.local["unlocked"].size() == unlocked0 and h.dev_break_seals() == 0, "F9 is a no-op for a normal account")
	h.settings_store.update({"dev_access": false})
	# a dev account (the server marks it GM: gm_enabled on the character)
	h.character["gm_enabled"] = true
	h.dev_account = true
	check(h.dev_account and not h.dev_access and not h.prog.dev_access, "dev account: GM mode is off at setup (settings default off)")
	h.settings_store.update({"dev_access": true})
	check(h.dev_access and h.prog.dev_access and g.gather.skills.dev_access, "GM mode on: progression and gathering follow")
	var caster := hero.get_node_or_null("Rites") as DmRiteCaster
	check(caster != null and caster.dev, "the host's own caster is told (locked rites cast)")
	check(g.chapterhouse != null and h.prog.is_unlocked("warren"), "sealed halls read as open")
	var m := events.size()
	h.settings_store.update({"dev_access": false})
	check(not h.dev_access and not h.prog.dev_access and not g.gather.skills.dev_access and not caster.dev and not h.prog.is_unlocked("warren"), "toggle off: everything closes again")
	check(since(m, "toast").any(func(x: Dictionary) -> bool: return String(x["text"]).begins_with("GM mode off")), "toast says so")
	check(h.dev_break_seals() == 0, "F9 does nothing with dev access off")
	m = events.size()
	h.settings_store.update({"dev_access": true})
	check(h.dev_access and h.prog.dev_access and caster.dev and since(m, "toast").any(func(x: Dictionary) -> bool: return String(x["text"]).begins_with("GM mode on")), "toggle on: effects return")
	var open_count := func() -> int:
		var n := 0
		for id in DmContent.area_order():
			if h.prog.really_unlocked(String(id)):
				n += 1
		return n
	var before: int = open_count.call()
	g.input._unhandled_input(f9)
	check(int(open_count.call()) == DmContent.area_order().size() and before < int(open_count.call()), "F9 breaks every seal (%d -> %d)" % [before, open_count.call()])
	check(h.prog.local["unlocked"].has("warren"), "and the break is real (saved state)")
	h.settings_store.update({"dev_access": false})
