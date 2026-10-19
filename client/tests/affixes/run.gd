extends SceneTree
## The elite affixes' roll and its place in the game (client/core/dm_affix_roll.gd, client/next/spawn). godot --headless --path client --script res://tests/affixes/run.gd
## A roll rules (count, omen forcing, Depths extras, Nightfall) and the numbers of the four affixes.
## F the real game scene (offline, solo): the director rolls, the Tolling omen forces Bell-Tolled, the Depths' count, an explicit list wins, a vengeful elite's Risen join the core.
## Not here: each affix's own rules, the corpse economy and the moments (tests/core_affixes.gd: they run in the combat core now, against today's timer arithmetic).

const DT := 1.0 / 60.0
var passed := 0
var failed := 0


func ok(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	DmSimData.ensure()
	_a_roll()
	await _f_game()
	print("%d passed, %d failed" % [passed, failed])
	print("%s affixes %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


func _seq(vals: Array) -> Callable:
	var i := [0]
	return func() -> float:
		var v: float = vals[i[0] % vals.size()]
		i[0] += 1
		return v


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


# ---- A ----------------------------------------------------------------------------------------------------------------------------------
func _a_roll() -> void:
	var T: Dictionary = DmSimData.AFFIX_TUNING
	ok(DmSimData.AFFIX_ORDER == ["bellTolled", "hungering", "shrouded", "vengeful"], "A: four affixes in the sim's order")
	ok(T["bellTolled"]["intervalS"] == 6 and T["bellTolled"]["windupS"] == 0.9 and T["bellTolled"]["r"] == 3 and T["bellTolled"]["damageMult"] == 0.6, "A: bell numbers")
	ok(T["hungering"]["intervalS"] == 4 and T["hungering"]["reach"] == 5 and T["hungering"]["healFrac"] == 0.15, "A: hungering numbers")
	ok(T["shrouded"]["damageTakenMult"] == 0.5 and T["vengeful"]["risen"] == 3, "A: shroud / vengeful numbers")
	# elite: one of the four by rand
	for i in 4:
		var l := DmAffixRoll.roll(true, "", -1.0, 0.0, _seq([(float(i) + 0.5) / 4.0]))
		ok(l.size() == 1 and l[0] == DmSimData.AFFIX_ORDER[i], "A: elite roll %d -> %s" % [i, DmSimData.AFFIX_ORDER[i]])
	ok(DmAffixRoll.roll(false, "", -1.0, 0.0, _seq([0.0])).is_empty(), "A: a plain body rolls nothing")
	# omen forcing: the Tolling's Bell-Tolled on every elite, whatever the dice say
	var tolling := {}
	for k in DmContent.get_export("omens", "OMENS"):
		var o: Dictionary = DmContent.get_export("omens", "OMENS")[k]
		if o.get("affix") != null:
			tolling = o
	ok(not tolling.is_empty() and tolling["affix"] == "bellTolled", "A: the Tolling omen carries bellTolled")
	for r in [0.0, 0.3, 0.6, 0.99]:
		var l := DmAffixRoll.roll(true, String(tolling["affix"]), -1.0, 0.0, _seq([r]))
		ok(l.size() == 1 and l[0] == "bellTolled", "A: omen forces Bell-Tolled (dice %.2f)" % r)
	ok(DmAffixRoll.roll(false, "bellTolled", -1.0, 0.0, _seq([0.0])).is_empty(), "A: the omen only touches elites")
	# Depths: 1 + extraAffixes(depth), distinct
	var D: Dictionary = DmSimData.DEPTHS
	for depth in [1, 5, 10, 15, 20, 40, 100]:
		var want := 1 + mini(int(D["maxExtraAffixes"]), int(floor(float(depth) / float(D["extraAffixEvery"]))))
		want = mini(want, 4)
		var rn := RandomNumberGenerator.new()
		rn.seed = depth
		var l := DmAffixRoll.roll(true, "", float(depth), 0.0, rn.randf)
		var distinct := {}
		for a in l:
			distinct[a] = true
		ok(l.size() == want and distinct.size() == l.size(), "A: depth %d elite bears %d distinct affixes (%d)" % [depth, want, l.size()])
	var forced := DmAffixRoll.roll(true, "bellTolled", 20.0, 0.0, _seq([0.1, 0.5, 0.9]))
	ok(forced[0] == "bellTolled" and forced.size() > 1 and forced.find("bellTolled", 1) == -1, "A: omen + depths: bell first, extras never repeat it")
	# Nightfall: non-elites shroud on the chance
	ok(DmAffixRoll.roll(false, "", -1.0, 0.3, _seq([0.1]))[0] == "shrouded", "A: Nightfall shrouds a plain body under the chance")
	ok(DmAffixRoll.roll(false, "", -1.0, 0.3, _seq([0.5])).is_empty(), "A: ...and not over it")


# ---- F ----------------------------------------------------------------------------------------------------------------------------------
func _has_status(core: RefCounted, id: int, name: StringName) -> bool:
	var b: PackedByteArray = core.statuses(id)
	var want := DmStatusSet.IDS.find(name)
	for i in range(0, b.size(), 4):
		if int(b[i]) == want:
			return true
	return false


## The real game scene (offline, solo): the director rolls, the Tolling omen forces Bell-Tolled, the Depths' count, a vengeful elite's Risen join the core.
func _f_game() -> void:
	var tolling := {}
	for k in DmContent.get_export("omens", "OMENS"):
		var o: Dictionary = DmContent.get_export("omens", "OMENS")[k]
		if o.get("affix") != null:
			tolling = o
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("af%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var ch := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["graves"], "dressing": false, "persist": false, "waves": false, "audio": false, "omen": tolling, "wander": false})
	var host: DmCoreHost = g.core_host
	var core: RefCounted = host.core
	var dir := g.director
	var b := g.local_body()
	b.p["god"] = true
	b.p["stats"]["maxHp"] = 1e9
	b.p["hp"] = 1e9
	b._mirror_from_state()
	var spot := b.position + Vector3(0, 0, -12)
	var plain: int = dir.spawn("robber", spot, [b], false)
	ok(plain > 0 and (core.enemy_info(plain)["affixes"] as PackedStringArray).is_empty(), "F: a plain enemy has no affixes")
	var tolled: int = dir.spawn("robber", spot + Vector3(2, 0, 0), [b], true)
	var tl: PackedStringArray = core.enemy_info(tolled)["affixes"]
	ok(tl == PackedStringArray(["bellTolled"]), "F: the Tolling omen forces Bell-Tolled on a director elite (%s)" % str(tl))
	ok(tl.size() == 1, "F: one affix on it")
	var depth_e: int = dir.spawn("robber", spot + Vector3(4, 0, 0), [b], true, {}, {"area": "depths", "depth": 20.0})
	var dl: PackedStringArray = core.enemy_info(depth_e)["affixes"]
	ok(dl.size() == 4 and dl[0] == "bellTolled", "F: a depth-20 elite bears 4 affixes, omen first (%s)" % str(dl))
	var forced: int = dir.spawn("robber", spot + Vector3(6, 0, 0), [b], true, {}, {"affix_list": PackedStringArray(["vengeful", "shrouded"])})
	var fl: Array = Array(core.enemy_info(forced)["affixes"])
	fl.sort()
	ok(fl == ["shrouded", "vengeful"], "F: an explicit affix_list wins (Depths run's own roll): the core holds the affixes as bits and lists them in the sim's order (%s)" % str(core.enemy_info(forced)["affixes"]))
	await ticks(12)
	ok(_has_status(core, forced, &"shrouded"), "F: the shroud is on the body (a status of the core)")
	core.stun(forced, 3600.0)
	var before := _risen(core)
	core.damage(forced, 1e9, b.core_id)
	await ticks(3)
	ok(_risen(core) - before == 3, "F: a vengeful elite's death adds 3 Risen to the core (%d)" % (_risen(core) - before))
	var dep: DmDepths = g.depths
	var lst: PackedStringArray = dep._affixes_of({"elite": true, "affix": "hungering", "extras": ["shrouded", "bellTolled", "vengeful"]})
	ok(lst == PackedStringArray(["bellTolled", "shrouded", "vengeful"]), "F: Depths order under the omen: forced first, no repeats (%s)" % str(lst))
	g.queue_free()
	await process_frame


func _risen(core: RefCounted) -> int:
	var n := 0
	for id in core.enemy_ids():
		if String(core.enemy_info(id)["def"]) == "risen":
			n += 1
	return n
