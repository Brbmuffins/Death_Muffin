extends SceneTree
## Brews + elite-affix chips on the rebuilt client (client/next/rewards, client/next/hud). godot --headless --fixed-fps 60 --path client --script res://tests/next_brews_affix/run.gd
## A wisdom / fortune from the active brew (DmRewardsMember.sync_brews, per member), expiry, per-member isolation.
## C target-frame affix chips on the core's elites, cached per target (no per-frame allocation), DmFrameCost.
## The lifesteal of the old suite's part B is tests/value.gd's (the hero's direct blows on the core's bodies); its part D (a puppet enemy's chips on an ENet client) is the core's
## replicated affix bits now (tests/core_affixes.gd).

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
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var r := await api.register("nb%d" % (Time.get_ticks_usec() % 100000), "p@example.com", "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(2)
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(c.data, api, {"dressing": false, "persist": false, "hud": true})
	await _a_rewards(g)
	await _c_chips(g)
	await g.leave()
	g.queue_free()
	await process_frame
	print("%d passed, %d failed" % [passed, failed])
	print("%s next_brews_affix %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


func _a_rewards(g: DmNextGame) -> void:
	var b := g.local_body()
	var m: DmRewardsMember = g.rewards.members[int(g.character.get("id", 0))]
	m.sync_brews()
	ok(m.wisdom == 0.0 and m.fortune == 0.0, "A: no brew, no bonus")
	var now := b.clock_ms()
	b.apply_brew("tonic_insight")
	m.sync_brews()
	ok(is_equal_approx(m.wisdom, DmBrews.brew_value(b.p["brews"], "wisdom", now)) and is_equal_approx(m.wisdom, 0.15) and m.fortune == 0.0, "A: tonic of insight -> wisdom 0.15 (%s)" % m.wisdom)
	b.apply_brew("tonic_graveluck")   # same slot: replaces
	m.sync_brews()
	ok(is_equal_approx(m.fortune, 0.15) and m.wisdom == 0.0, "A: grave-luck replaces insight (tonic slot): fortune 0.15, wisdom 0")
	# the kill path syncs by itself: the reward reads the member's multipliers
	m.fortune = 0.0
	m.wisdom = 0.0
	b.apply_brew("tonic_insight")
	var pos := b.global_position
	g.rewards.on_kill({"def": "robber", "x": pos.x, "z": pos.z, "area": "graves", "level": 1.0, "elite": false, "killer": b})
	ok(is_equal_approx(m.wisdom, 0.15), "A: a kill syncs wisdom before the reward (%s)" % m.wisdom)
	b.p["brews"]["tonic"]["until"] = 0.0   # expired
	m.sync_brews()
	ok(m.wisdom == 0.0 and m.fortune == 0.0, "A: expired brew clears the bonus")
	# per member: a second member's body keeps its own brews
	var other := DmRewardsMember.new()
	var stub := Node3D.new()
	g.add_child(stub)
	other.body = stub
	other.wisdom = 0.3
	other.sync_brews()
	ok(other.wisdom == 0.3, "A: a body without a rules state keeps hand-set values (stubs)")
	stub.queue_free()
	b.p["brews"]["tonic"] = null


func _c_chips(g: DmNextGame) -> void:
	var h := g.ui_host
	var host := g.core_host
	var core := host.core
	var at: Vector3 = g.local_body().position + Vector3(3, 0, 0)
	# an elite of the core (rising: false, a huge health pool, harmless and still), first with no affixes
	var plain := host.spawn_enemy("robber", at, 1, 1.0e5, 0.0, true, "graves", false)
	core.stun(plain, 3600.0)
	h._target_id = plain
	h._target_until = Time.get_ticks_msec() + 60000.0
	var hv := DmNextHudVm.new(h)
	var t0: Variant = hv._target()
	ok(t0 != null and (t0["affixes"] as Array).is_empty(), "C: a plain enemy has no chips (id %d: %s)" % [plain, str(t0 != null)])
	host.remove_enemy(plain)
	# then one that carries Hungering and Shrouded from its spawn
	var id := host.spawn_enemy("robber", at, 1, 1.0e5, 0.0, true, "graves", false, PackedStringArray(["hungering", "shrouded"]))
	core.stun(id, 3600.0)
	h._target_id = id
	h._target_until = Time.get_ticks_msec() + 60000.0
	var t1: Dictionary = hv._target()
	var ed: Dictionary = DmContent.get_export("enemies", "ELITE_AFFIXES")
	ok(t1["affixes"] == [{"id": "hungering", "name": ed["hungering"]["name"]}, {"id": "shrouded", "name": ed["shrouded"]["name"]}], "C: chips = DmGameHud's [{id, name}] (%s)" % str(t1["affixes"]))
	ok(String(t1["blurb"]) == ed["hungering"]["blurb"] + " " + ed["shrouded"]["blurb"], "C: blurb lists every affix, as the current game")
	var t2: Dictionary = hv._target()
	ok(is_same(t1["affixes"], t2["affixes"]), "C: the chip array is cached while the target is held (no per-frame rebuild)")
	ok(core.strip_shroud(id), "C: the core strips the shroud (Last Light / a Warden sweep)")
	var t3: Dictionary = hv._target()
	ok((t3["affixes"] as Array).size() == 1 and t3["affixes"][0]["id"] == "hungering", "C: a stripped shroud drops its chip")
	# cost of the held-target read: no allocation of the chip array, just the dictionary the HUD wants
	var n := 20000
	var t := Time.get_ticks_usec()
	for i in n:
		hv._affix_chips(id, PackedStringArray(["hungering"]), "")
	var per := float(Time.get_ticks_usec() - t) / float(n)
	print("PERF chips cached read %.3f us/call" % per)
	perf_info(per < 2.0, "C: cached chip read under 2 us (%.3f)" % per)
	# a real held-target frame: the HUD (20 Hz) reads the target every apply
	var fc := DmFrameCost.attach(root)
	var end := Engine.get_physics_frames() + 180
	while Engine.get_physics_frames() < end:
		await physics_frame
	print("PERF held elite target (1 chip) frame median %.2f ms p95 %.2f ms over %d frames" % [fc.pct(0.5), fc.pct(0.95), fc.samples()])
	fc.queue_free()
	h._target_until = 0.0
	host.remove_enemy(id)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
