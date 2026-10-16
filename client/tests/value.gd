extends SceneTree
## Value on the server in the game scene on the core (ROADMAP "Bring everything over": value on the server; client/README.md "Value on the server"), headless, against the
## local mock backend only (never a real server). The real scene with a Gravecaller; kills are made through the core (`DmCoreHost.damage` with the hero's id), so they
## take the real path: the core's EV_ENEMY_DIED -> the game's `kill_credited` (once) -> the ported DmSessionRewards. Checks:
##   A start: the backend's party session is open with this player's member, its drop tape filled; the progression, the Chronicle, the meta world and the bag are loaded;
##     the HUD's adapter (DmNextUiHost) reads the member's progression;
##   B kills: each one credited once and earned by the member in range; the Kill Chain and Soul Harvest count the hero's own; nothing is applied before the backend accepts; a flush
##     applies the XP and the kill counts and the server's counters agree; a thrall's kill is its owner's; the HUD's level, XP and chain follow;
##   C gold and shards go straight to the purse (pooled over goldEveryKills kills, elites pay at once), and the HUD shows them; the upgrades box shows by today's rule;
##   D a drop from the tape lies on the ground: walking over it takes nothing, a click (request) and the walk claim it, and the server's roll is in the bag;
##   E the brews: the tonic's wisdom is read per kill; lifesteal heals on the hero's direct blows (DmCoreHost.struck) only, never on a DoT tick, a thrall's swing or a
##     blow with no hero behind it (today's tests/next_brews_affix B, by DmBrews.lifesteal_heal);
##   F the meta: difficulty reaches the director, the rewards and the bosses; the Omen's multipliers the member; saved vows and boons do nothing (B36);
##   G the belt: Q drinks a flask from the bag (the mock's new character carries three);
##   H saving: flush_all ends the session with its last batch, and the character the backend holds carries the XP, level and gold.
## ZERO script errors or engine errors in the log. Run: godot --headless --fixed-fps 60 --path client --script res://tests/value.gd

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
var hero: DmHeroBody
var api: DmApi
var m: DmRewardsMember
var credited: Array = []           ## [enemy id, killer peer] per kill_credited


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL value: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func _initialize() -> void:
	OS.add_logger(errlog)
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var reg := await api.register("value%d" % (Time.get_ticks_usec() % 100000), "v@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "persist": false})
	host = g.core_host
	hero = g.local_body()
	g.kill_credited.connect(func(id: int, _d: String, _l: int, _e: bool, _a: String, peer: int, _x: float, _z: float) -> void: credited.append([id, peer]))
	await _a_start()
	await _b_kills()
	await _c_purse()
	await _d_drops()
	await _e_brews()
	_f_meta()
	await _g_belt()
	await _h_saving()
	for e in errlog.errors:
		printerr("ERROR in log: " + e)
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d)" % errlog.errors.size())
	print("%s value %d checks%s" % ["PASS" if fails == 0 else "FAIL", checks, "" if fails == 0 else " (%d failed)" % fails])
	quit(1 if fails > 0 else 0)


## A level-1 enemy of the Graves `d` metres east of the hero (not rising: it can be hit at once).
func _enemy(d: float = 3.0, elite: bool = false, hp_mult: float = 1.0, def: String = "robber") -> int:
	return host.spawn_enemy(def, hero.position + Vector3(d, 0.0, 0.0), 1, hp_mult, 0.0, elite, "graves", false)


## The hero's blow kills it; the death is credited when the core's events are dispatched (the next tick).
func _kill(id: int) -> void:
	host.damage(id, 1.0e6, hero.core_id)
	await ticks(2)


# ------------------------------------------------------------------------------------------------------------------ A

func _a_start() -> void:
	check(g.rewards is DmSessionRewards and g.rewards.session_id.length() > 0, "the host's party session is open on the backend (%s)" % g.rewards.session_id)
	m = g.my_member()
	check(m != null and m.body == hero and m.api == api and m.peer_id == g.session.get_my_id(), "this player's rewards member: its body, its own api, its peer")
	var n := 0
	while (m.tape == null or not m.tape.ready_for("elite")) and n < 120:
		await process_frame
		n += 1
	check(m.tape != null and m.tape.ready_for("elite"), "the member's drop tape is dealt (server-decided drops, B20)")
	check(g.progress != null and g.progress.prog == m.prog and m.prog.mode == "server", "the progression is the member's and talks to the server (%s)" % m.prog.mode)
	check(g.chron != null and m.trophy_store.is_valid(), "the Chronicle keeps the first-kill trophies")
	check(g.meta != null and g.meta.member == m and not g.meta.omen.is_empty(), "the meta world: this member, the week's Omen")
	check(g.loot != null and g.loot.inventory != null and g.loot.slots().size() == 2, "the bag is the server's (%d rows)" % (g.loot.slots().size() if g.loot != null else -1))
	check(g.ui_host.prog == m.prog and g.ui_host.character == g.character and m.prog.character == g.character, "the HUD's adapter reads the member's progression and the game's character")
	check(m.take_item.is_valid() and m.loot_view.rune_owned.is_valid() and m.loot_view.claim_requested.is_connected(g.loot._on_claim), "the loot node takes, claims and knows the runes owned")


# ------------------------------------------------------------------------------------------------------------------ B

func _b_kills() -> void:
	var xp0 := int(g.character.get("experience", 0))
	var kills0 := int(m.prog.local["totalKills"])
	credited.clear()
	var souls0 := float(hero.p["souls"])
	var ids: Array = []
	for i in 4:
		ids.append(_enemy(3.0 + i))
	for id: int in ids:
		await _kill(id)
	check(credited.size() == 4 and int(credited[0][1]) == g.session.get_my_id(), "four kills, each credited once, to this player's peer (%s)" % str(credited))
	check(int(m.stats["kills_earned"]) == 4, "the member earned the four (%s)" % str(m.stats))
	check(m.chain.count == 4, "the Kill Chain counts the hero's own kills (%d)" % m.chain.count)
	check(float(hero.p["souls"]) == minf(float(hero.p["soulsMax"]), souls0 + 4.0), "Soul Harvest banks a soul for each of the hero's own kills (%s -> %s)" % [souls0, hero.p["souls"]])
	check(int(m.prog.local["totalKills"]) == kills0 and int(g.character.get("experience", 0)) == xp0, "nothing is applied before the backend accepts")
	await g.rewards.flush()
	check(int(m.stats["kills_accepted"]) == 4 and int(m.prog.local["totalKills"]) == kills0 + 4, "the accepted report applies the kill counts (%s)" % str(m.stats))
	check(int(m.stats["xp_applied"]) > 0 and int(g.character.get("experience", 0)) + _xp_below(int(g.character.get("level", 1))) == xp0 + int(m.stats["xp_applied"]),
		"the accepted report applies the XP (%d)" % int(m.stats["xp_applied"]))
	var sv: DmResult = await api.session_get(g.rewards.session_id)
	check(sv.ok and int(sv.data["members"][0]["acceptedKills"]) == 4, "the server counted four for this character")
	# a thrall's blow: the kill is its owner's
	var c := hero.get_node("Rites") as DmRiteCaster
	var th := c.thralls()
	var st := DmThralls.raise_stats({"kind": "normal", "cap": 3.0, "hp": 200.0, "damage": 10.0, "attackSpeedMult": 1.0}, {"kind": "normal", "enemy": "risen", "elite": false}, 1.0, 1, 0.0)
	var tid := int(host.core.raise_thrall(st, hero.core_id, Vector2(hero.position.x + 1.0, hero.position.z), 0.0, 3.0))
	check(tid != 0, "a thrall stands beside the hero")
	credited.clear()
	var e := _enemy(4.0)
	host.damage(e, 1.0e6, tid)
	await ticks(2)
	check(credited.size() == 1 and int(credited[0][1]) == g.session.get_my_id(), "a thrall's kill is credited to its owner's peer (%s)" % str(credited))
	th.clear()
	await ticks(2)
	var vm := g.ui_host.hud_state()
	check(int(vm["level"]) == int(g.character["level"]) and vm["xp"] == g.character["experience"], "the HUD shows the level and XP the server accepted")
	check(vm["chain"] is Dictionary and int(vm["chain"]["count"]) == m.chain.count, "the HUD's Kill Chain meter counts with the member's chain")


## XP of the levels below `level` (the character's XP counts from its current level).
func _xp_below(level: int) -> int:
	var t := 0
	for l in range(1, level):
		t += DmProgression.xp_to_next(l)
	return t


# ------------------------------------------------------------------------------------------------------------------ C

func _c_purse() -> void:
	var gold0 := int(g.character.get("gold", 0))
	var picked0 := int(m.stats["gold_picked"])
	var elite := _enemy(3.0, true)
	await _kill(elite)
	await ticks(3)   # the ground credits gold on the rewards' next tick
	check(int(m.stats["gold_picked"]) > picked0 and int(g.character.get("gold", 0)) == gold0 + int(m.stats["gold_picked"]) - picked0, "an elite's gold goes straight to the purse (%d)" % (int(m.stats["gold_picked"]) - picked0))
	var only_items := true
	for d in m.loot_view.debug_drops():
		only_items = only_items and d["kind"] == "item"
	check(only_items, "nothing but items lies on the ground (gold and shards never wait)")
	var vm := g.ui_host.hud_state()
	check(int(vm["gold"]) == int(g.character["gold"]) and int(vm["shards"]) == int(m.prog.local["shards"]), "the HUD shows the purse (%d gold)" % int(vm["gold"]))
	await ticks(10)   # the HUD's next reveal tick (DmGameUi._progressive_tick: gold earned in hunting ground)
	check(g.ui.reveal.has("hud.upgrades") and g.ui.hud.up_plate.visible, "the upgrades box shows once the character has earned")


# ------------------------------------------------------------------------------------------------------------------ D

func _d_drops() -> void:
	var d: Dictionary = {}
	var n := 0
	while d.is_empty() and n < 40:
		await _kill(_enemy(3.0, true))
		for x: Dictionary in m.loot_view._drops:
			if (x["item"] as Dictionary).has("claim"):
				d = x
		n += 1
	check(not d.is_empty(), "an elite kill dropped an item from the tape (%d kills)" % n)
	if d.is_empty():
		return
	var item: Dictionary = d["item"]
	var count0 := m.loot_view.count()
	hero.teleport(Vector3(float(d["x"]), 0.0, float(d["z"])))
	await ticks(10)
	check(m.loot_view.count() == count0 and m.loot_view._drops.has(d), "walking over a drop takes nothing")
	var bag0 := _count_of(String(item["claim"]["expect"]))
	var at: Vector3 = (d["node"] as Node3D).global_position + Vector3(0, 0.7, 0)
	check(g.loot.loot_click(g.camera.unproject_position(at)), "a click on the drop picks it (DmNextLoot.loot_click, the input's path)")
	var k := 0
	while m.loot_view._drops.has(d) and k < 120:
		await process_frame
		k += 1
	check(not m.loot_view._drops.has(d), "a click and the walk claim the drop (%d frames)" % k)
	check(_count_of(String(item["claim"]["expect"])) > bag0, "the server's roll of %s is in the bag" % String(item["claim"]["expect"]))
	check(int(m.stats["items_picked"]) >= 1, "the member counts the item picked")


func _count_of(item_id: String) -> int:
	var n := 0
	for r: Dictionary in g.loot.slots():
		if String(r.get("item_id", "")) == item_id:
			n += int(r.get("quantity", 1))
	return n


# ------------------------------------------------------------------------------------------------------------------ E

func _e_brews() -> void:
	m.sync_brews()
	check(m.wisdom == 0.0 and m.fortune == 0.0, "no brew, no bonus")
	hero.apply_brew("tonic_insight")
	var e := _enemy(3.0)
	m.wisdom = 0.0
	await _kill(e)
	check(is_equal_approx(m.wisdom, 0.15), "a kill reads the tonic's wisdom before the reward (%s)" % m.wisdom)
	hero.p["brews"]["tonic"] = null
	# lifesteal: the hero's direct blows only
	var cap: float = float(DmCombatData.load_json("brews")["lifesteal_hit_cap"])
	var foe := _enemy(3.0, false, 1.0e5)
	hero.p["hp"] = hero.max_hp * 0.3
	hero.heal(0.0)
	var hp0 := hero.hp
	host.damage(foe, 100.0, hero.core_id)
	g.rewards._flush_lifesteal()   # the end-of-frame flush, without a frame of regen
	check(is_equal_approx(hero.hp, hp0), "no elixir, no heal")
	hero.apply_brew("elixir_leechblood")   # 4 %
	hp0 = hero.hp
	host.damage(foe, 100.0, hero.core_id)
	g.rewards._flush_lifesteal()
	var want := DmBrews.lifesteal_heal(100.0, 1.0, 0.04, hero.max_hp)
	check(want >= 1.0 and is_equal_approx(hero.hp - hp0, want), "leechblood heals 4%% of a 100 blow: %.2f (got %.2f)" % [want, hero.hp - hp0])
	hp0 = hero.hp
	host.damage(foe, 1.0e4, hero.core_id)
	g.rewards._flush_lifesteal()
	check(is_equal_approx(hero.hp - hp0, minf(hero.max_hp * cap, hero.max_hp - hp0)), "a huge blow heals at most %.0f%% of max health (got %.1f)" % [cap * 100.0, hero.hp - hp0])
	hero.p["hp"] = hero.max_hp * 0.3
	hero.heal(0.0)
	hp0 = hero.hp
	host.damage(foe, 100.0, 0)   # no hero behind it
	g.rewards._flush_lifesteal()
	check(is_equal_approx(hero.hp, hp0), "a blow with no hero behind it does not heal")
	var struck := [0]
	var dots := [0]
	host.struck.connect(func(_i: int, _s: int, _d: float) -> void: struck[0] += 1)
	host.status_dot.connect(func(id: int, _st: int, src: int, _k: bool, _a: float) -> void:
		if id == foe and src == hero.core_id:
			dots[0] += 1)
	hero.apply_brew("elixir_leechblood")
	host.apply_status(foe, "withered", hero.core_id, 6.0, 4.0, {"dps": 20.0})
	await ticks(60)   # a second of Withered lumps
	check(dots[0] > 0 and struck[0] == 0 and g.rewards._ls_acc.is_empty(), "a DoT tick of the hero's is not a direct blow: nothing for lifesteal (%d ticks, %d struck)" % [dots[0], struck[0]])
	hero.p["brews"]["elixir"] = null
	host.remove_enemy(foe)


# ------------------------------------------------------------------------------------------------------------------ F

func _f_meta() -> void:
	g.meta.set_difficulty("hard", true)
	check(g.director.difficulty == "hard" and g.rewards.difficulty == "hard" and g.bosses.difficulty == "hard", "difficulty reaches the director, the rewards and the bosses")
	g.meta.set_difficulty("medium", true)
	check(is_equal_approx(m.omen_reward, float(g.meta.omen.get("rewardMult", 1.0))) and is_equal_approx(m.omen_shard, float(g.meta.omen.get("shardMult", 1.0))),
		"the Omen's multipliers are the member's (%s)" % String(g.meta.omen.get("name", "")))
	# Ascension is not in the rebuild (DECISIONS B36): saved vows and boons do nothing (no heat, no world vows, no boon on the hero)
	var me := g.session.get_my_id()
	var hp_mult := float(g.build_for(me)["discipline"]["mods"]["maxHpMult"])
	var local: Dictionary = g.progress.prog.local
	var saved := [local.get("vows"), local.get("boons")]
	local["vows"] = {"iron_dead": 2, "frail_vessel": 1, "elder_dead": 3}
	local["boons"] = {"vigil": 2, "bonded_dead": 1, "lingering_dead": 1}
	g.progress.apply_progress()
	check(g.meta.heat == 0 and g.rewards.ascension == 0.0 and m.self_heat == 0 and g.rewards.vow_levels == 0.0, "saved vows bring no heat and no rank (B36)")
	check(g.director.vow_fx == DmVowsBoons.vow_effects({}) and g.bosses.vow_fx == g.director.vow_fx, "the world runs without vows: the director's and the bosses' effects are neutral")
	check(float(g.build_for(me)["discipline"]["mods"]["maxHpMult"]) == hp_mult, "the hero's build ignores the saved vows and boons (max health x%s)" % hp_mult)
	local["vows"] = saved[0]
	local["boons"] = saved[1]
	g.progress.apply_progress()


# ------------------------------------------------------------------------------------------------------------------ G

func _g_belt() -> void:
	var flasks0 := _count_of("flask_hp_minor")
	hero.p["hp"] = hero.max_hp * 0.3
	hero.heal(0.0)
	var hp0 := hero.hp
	var q := InputEventKey.new()
	q.keycode = KEY_Q
	q.pressed = true
	g.ui_host._unhandled_key_input(q)
	await ticks(2)
	check(_count_of("flask_hp_minor") == flasks0 - 1, "Q drinks a flask from the bag (%d -> %d)" % [flasks0, _count_of("flask_hp_minor")])
	check(hero.hp > hp0, "the flask heals the hero")
	var brews: Array = g.ui_host.hud_state()["brews"]
	check(not brews.is_empty(), "the HUD's belt shows the flask and the brew slots (%d)" % brews.size())


# ------------------------------------------------------------------------------------------------------------------ H

func _h_saving() -> void:
	await _kill(_enemy(3.0))
	var sid: String = g.rewards.session_id
	await g.flush_all()
	check(g.rewards.ended, "flush_all ends the rewards session")
	var sv: DmResult = await api.session_get(sid)
	check(sv.ok and String(sv.data["status"]) == "ended" and int(sv.data["members"][0]["acceptedKills"]) == int(m.stats["kills_accepted"]),
		"the last batch went with the end (%d accepted)" % (int(sv.data["members"][0]["acceptedKills"]) if sv.ok else -1))
	var cr: DmResult = await api.get_character()
	var saved: Dictionary = cr.data if cr.ok and cr.data is Dictionary else {}
	check(int(saved.get("level", 0)) == int(g.character["level"]) and int(saved.get("experience", -1)) == int(g.character["experience"]) and int(saved.get("gold", -1)) == int(g.character["gold"]),
		"the backend holds the level, XP and gold earned (%s)" % str([saved.get("level"), saved.get("experience"), saved.get("gold")]))
	check(g.ui_host.save_chip()["text"] == "Saved ✓", "the save chip says saved (%s)" % g.ui_host.save_chip()["text"])
	await g.leave()
