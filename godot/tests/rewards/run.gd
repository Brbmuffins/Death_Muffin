extends SceneTree
## DmSessionRewards against the OFFLINE backend only (never a real server). Headless:
##   godot --headless --path godot --script res://tests/rewards/run.gd
## The shell is a test double (a Node with `enemy_spawned`); enemies are real DmEnemy robbers (brain only, no nav/visuals).

var _p := 0
var _f := 0
var _clock := [1_790_000_000_000]
var _users := 0


class Shell extends Node:
	signal enemy_spawned(enemy)


func ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		_p += 1
	else:
		_f += 1
		print("FAIL: ", label, " ", extra)


func _initialize() -> void:
	_main.call_deferred()


## An API whose transport can drop the reply of the next /report (the backend still processes it) or rewrite what it accepted.
class Wire extends RefCounted:
	var inner: Callable
	var drop_next_report := false
	var halve_next_report := false
	var reports_seen := 0
	func call_it(req: Dictionary) -> Dictionary:
		var resp: Dictionary = await inner.call(req)
		if String(req["url"]).ends_with("/report"):
			reports_seen += 1
			if drop_next_report:
				drop_next_report = false
				return {"status": 0, "text": "", "network_error": true}
			if halve_next_report:
				halve_next_report = false
				var j: Variant = JSON.parse_string(String(resp["text"]))
				for e in j["data"]["members"]:
					if e.get("credited", false):
						e["accepted"]["kills"] = int(e["accepted"]["kills"]) / 2
				resp["text"] = JSON.stringify(j)
		return resp


func _user(mock: DmMockBackend, name: String, wire: Wire = null) -> Array:
	var api := DmOffline.make_api(mock)
	if wire != null:
		wire.inner = mock.transport_callable()
		api.transport = Callable(wire, "call_it")
	var reg := await api.register(name, "", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(1 + (_users % 3))
	_users += 1
	return [api, int(ch.data["id"])]


func _body(at: Vector3) -> Node3D:
	var b := Node3D.new()
	root.add_child(b)
	b.position = at
	return b


func _robber(shell: Shell, at: Vector3) -> DmEnemy:
	var e: DmEnemy = load("res://enemies/robber.tscn").instantiate()
	e.use_nav = false
	e.with_visual = false
	e.wander_enabled = false
	e.use_avoidance = false
	e.position = at
	e.set_meta("dm_level", 1)
	root.add_child(e)
	shell.enemy_spawned.emit(e)
	return e


func _kill(e: DmEnemy, by: Node3D) -> void:
	e.take_damage(1e9, by, false)


func _new_rewards(shell: Shell) -> DmSessionRewards:
	var r := DmSessionRewards.new()
	r.auto_tick = false
	r.rng = func() -> float: return 0.0   # every chance hits: loot, gear, elite shards
	r.now_ms = func() -> int: return _clock[0]
	root.add_child(r)
	r.attach_spawner(shell)
	return r


func _wait_gear(r: DmSessionRewards) -> void:
	var n := 0
	while r.gear_pending() > 0 and n < 600:
		await process_frame
		n += 1


func _main() -> void:
	DmSimData.ensure()
	await _t_solo()
	await _t_two_members()
	await _t_lost_reply_and_partial()
	await _t_refusals()
	await _t_end()
	print("%d passed, %d failed" % [_p, _f])
	quit(1 if _f > 0 else 0)


# ---------------------------------------------------------------------------------------------------------------- solo

func _t_solo() -> void:
	var mock := DmOffline.make_mock("")
	mock.now_ms = func(): return _clock[0]
	var u = await _user(mock, "solo")
	var shell := Shell.new()
	root.add_child(shell)
	var r := _new_rewards(shell)
	var hero := _body(Vector3.ZERO)
	var m := DmRewardsMember.make(u[1], 1, hero, u[0])
	r.add_member(m)
	ok(await r.start(u[1]), "solo session opens")
	ok(r.session_id.length() == 32, "session id from the backend")
	var credited := []
	r.member_credited.connect(func(cid, d): credited.append(d))
	var enemies: Array = []
	for i in 5:
		enemies.append(_robber(shell, Vector3(3, 0, i * 0.2)))
	for e in enemies:
		_kill(e, hero)
	ok(m.stats["kills_earned"] == 5, "five kills earned by the lone member", str(m.stats))
	ok(m.prog.local["totalKills"] == 0 and m.prog.character["experience"] == 0, "nothing applied before the backend accepts")
	await r.flush()
	ok(r.batch_no == 1 and credited.size() == 1, "one batch accepted", str(credited))
	ok(m.stats["kills_accepted"] == 5 and m.prog.local["totalKills"] == 5, "accepted kill counts applied", str(m.stats))
	ok(m.prog.local["areaKills"].get("graves", 0) == 5, "area kills banked")
	ok(m.stats["xp_applied"] > 0, "xp applied from the accepted batch", str(m.stats))
	var total_xp := int(m.prog.character["experience"])
	for l in range(1, int(m.prog.character["level"])):
		total_xp += DmProgression.xp_to_next(l)
	ok(total_xp == m.stats["xp_applied"], "level + xp match what was applied")
	var v: DmResult = await u[0].session_get(r.session_id)
	ok(v.ok and v.data["members"][0]["acceptedKills"] == 5, "backend counted 5", str(v.data))
	# batching by time
	_robber(shell, Vector3(2, 0, 0))
	var late: DmEnemy = _robber(shell, Vector3(2, 0, 1))
	_kill(late, hero)
	r.flush_interval = 5.0
	r.tick(5.1)
	await create_timer(0.1).timeout
	await r.flush()   # waits for the timer-started flush
	ok(r.batch_no == 2 and m.stats["kills_accepted"] == 6, "timer flushes a second batch with an increasing number", str(r.batch_no))
	await _wait_gear(r)

	# loot: pick up by walking over it; the ground view has this member's drops
	var drops: Array = m.loot_view.debug_drops()
	ok(drops.size() > 0, "kills left drops on the ground", str(drops))
	var kinds := {}
	for d in drops:
		kinds[d["kind"]] = true
	ok(kinds.has("gold"), "pooled gold pile dropped after 4 kills")
	ok(m.loot_view.count() == drops.size(), "debug_drops matches count")
	r.tick(0.6)   # hero stands far from drops? (0,0,0) vs kills at x=2..3: gold magnets, items need <1.3
	for d in m.loot_view.debug_drops():
		hero.position = Vector3(d["x"], 0, d["z"])
		r.tick(0.5)
	for i in 6:
		r.tick(0.5)
	ok(m.loot_view.count() == 0, "walking over every drop clears the ground", str(m.loot_view.debug_drops()))
	ok(m.stats["gold_picked"] > 0 and int(m.prog.character["gold"]) == m.stats["gold_picked"], "gold pickup paid", str(m.stats))
	ok(m.bag.size() > 0 or m.stats["items_picked"] == 0, "picked items are in the bag")
	var item_n := 0
	for it in m.bag:
		item_n += int(it["quantity"])
	ok(item_n == m.stats["items_picked"], "bag matches items picked")
	ok(m.stats["shards_picked"] >= 0, "shards counted")

	# loot expires, never flies: stand away, drops do not move
	hero.position = Vector3(30, 0, 0)
	var e2 := _robber(shell, Vector3(30, 0, 8))
	hero.position = Vector3(30, 0, 0)
	_kill(_robber(shell, Vector3(30, 0, 8)), hero)
	await _wait_gear(r)
	var before: Array = m.loot_view.debug_drops()
	ok(before.size() > 0, "a far kill still dropped loot (8 m is in range)")
	var exp_seen := []
	r.loot_expired.connect(func(cid, d, reason): exp_seen.append(reason))
	r.tick(10.0)
	var after: Array = m.loot_view.debug_drops()
	var moved := false
	for i in mini(before.size(), after.size()):
		if before[i]["kind"] == "item" and (before[i]["x"] != after[i]["x"] or before[i]["z"] != after[i]["z"]):
			moved = true
	ok(not moved, "item loot never flies toward the hero")
	hero.position = Vector3(500, 0, 500)
	r.tick(61.0)
	ok(m.loot_view.count() == 0 and exp_seen.size() > 0 and exp_seen[0] == "ttl", "unclaimed loot expires after 60 s", str(exp_seen))
	var gold_before: int = m.stats["gold_picked"]
	r.tick(1.0)
	ok(m.stats["gold_picked"] == gold_before, "expired loot pays nothing")
	# a dead hero picks nothing up
	hero.set_script(null)
	e2.free()
	await r.end_session()
	ok(r.ended, "session ends")
	shell.queue_free()
	r.queue_free()


# ---------------------------------------------------------------------------------------------------------------- party

func _t_two_members() -> void:
	var mock := DmOffline.make_mock("")
	mock.now_ms = func(): return _clock[0]
	var ua = await _user(mock, "alice")
	var ub = await _user(mock, "bob")
	var uc = await _user(mock, "cara")
	var shell := Shell.new()
	root.add_child(shell)
	var r := _new_rewards(shell)
	var a_body := _body(Vector3(0, 0, 0))
	var b_body := _body(Vector3(20, 0, 0))
	var c_body := _body(Vector3(100, 0, 0))
	var a := DmRewardsMember.make(ua[1], 1, a_body, ua[0])
	var b := DmRewardsMember.make(ub[1], 2, b_body, ub[0])
	var c := DmRewardsMember.make(uc[1], 3, c_body, uc[0])
	b.wisdom = 0.5
	r.add_member(a)
	r.add_member(b)
	r.add_member(c)
	ok(await r.start(ua[1]), "party session opens with three members")
	var sv: DmResult = await ua[0].session_get(r.session_id)
	ok(sv.ok and sv.data["members"].size() == 3, "members joined with their own APIs", str(sv.data))
	ok(a.loot_view.visible and not b.loot_view.visible, "a view is visible only to its own peer (local peer 1)")

	# proximity parity with the current game's rule
	var rules := DmGameRewards.new(null)
	var parity_ok := true
	for dist in [0.0, 10.0, 37.9, 38.0, 38.1, 80.0]:
		for alive in [true, false]:
			var got := false
			var body := _body(Vector3(float(dist), 0, 0))
			var tmp := DmRewardsMember.make(9, 1, body, null)
			if not alive:
				body.set_script(load("res://tests/rewards/dead_body.gd"))
			var probe := DmSessionRewards.new()
			probe.auto_tick = false
			root.add_child(probe)
			probe.add_member(tmp)
			probe.on_kill({"def": "robber", "area": "graves", "level": 1, "elite": false, "x": 0.0, "z": 0.0, "killer": null})
			got = tmp.stats["kills_earned"] == 1
			if got != rules.boss_reward_eligible(alive, float(dist)):
				parity_ok = false
				print("  parity mismatch at ", dist, " alive=", alive)
			probe.queue_free()
			body.queue_free()
	ok(parity_ok, "who earns a kill matches DmGameRewards.boss_reward_eligible (range 38, alive)")

	var e := _robber(shell, Vector3(5, 0, 0))
	_kill(e, a_body)   # alice kills at x=5: alice 5 m, bob 15 m, cara 95 m
	ok(a.stats["kills_earned"] == 1 and b.stats["kills_earned"] == 1 and c.stats["kills_earned"] == 0, "killer and the party in range earn it, far member does not", str([a.stats["kills_earned"], b.stats["kills_earned"], c.stats["kills_earned"]]))
	ok(a.chain.count == 1 and b.chain.count == 0, "kill chain only for the killer")
	await _wait_gear(r)
	ok(a.loot_view.count() > 0 and b.loot_view.count() > 0 and c.loot_view.count() == 0, "each member that earned it has its OWN drops", str([a.loot_view.count(), b.loot_view.count(), c.loot_view.count()]))
	# alice standing on bob's drops gets nothing from them; bob's pickup is bob's
	var bd: Array = b.loot_view.debug_drops()
	a_body.position = Vector3(bd[0]["x"], 0, bd[0]["z"])
	r.tick(1.0)
	ok(b.loot_view.count() == bd.size(), "another member walking over my drops does not take them")
	b_body.position = Vector3(bd[0]["x"], 0, bd[0]["z"])
	r.tick(1.0)
	ok(b.loot_view.count() < bd.size() or b.stats["gold_picked"] > 0, "the owner walking over them picks them up")
	# each member's report at its own multipliers; wisdom raises bob's XP
	var more := 0
	for i in 3:
		_kill(_robber(shell, Vector3(5, 0, i)), a_body)
	await r.flush()
	ok(a.stats["kills_accepted"] == 4 and b.stats["kills_accepted"] == 4 and c.stats["kills_accepted"] == 0, "backend accepted each earner's kills", str([a.stats, b.stats]))
	ok(b.stats["xp_applied"] > a.stats["xp_applied"], "a member's own multiplier (wisdom) applies to its XP", str([a.stats["xp_applied"], b.stats["xp_applied"]]))
	var v: DmResult = await ua[0].session_get(r.session_id)
	var counts := {}
	for mm in v.data["members"]:
		counts[int(mm["characterId"])] = int(mm["acceptedKills"])
	ok(counts[ua[1]] == 4 and counts[ub[1]] == 4 and counts[uc[1]] == 0, "per-member counters on the backend", str(counts))
	# heartbeats go out with each member's own API
	_clock[0] += 30000
	r.tick(21.0)
	await create_timer(0.05).timeout
	var hb: DmResult = await ub[0].session_heartbeat(r.session_id, ub[1], 4)
	ok(hb.ok and hb.data.get("throttled", false), "the host's tick already heartbeated bob (a second call is throttled)", str(hb.data))
	await r.end_session()
	shell.queue_free()
	r.queue_free()


# ---------------------------------------------------------------------------------------------------------------- duplicates, partial

func _t_lost_reply_and_partial() -> void:
	var mock := DmOffline.make_mock("")
	mock.now_ms = func(): return _clock[0]
	var wire := Wire.new()
	var u = await _user(mock, "wired", wire)
	var shell := Shell.new()
	root.add_child(shell)
	var r := _new_rewards(shell)
	var hero := _body(Vector3.ZERO)
	var m := DmRewardsMember.make(u[1], 1, hero, u[0])
	r.add_member(m)
	await r.start(u[1])
	for i in 3:
		_kill(_robber(shell, Vector3(2, 0, i)), hero)
	wire.drop_next_report = true
	await r.flush()
	ok(r.batch_no == 1 and m.stats["kills_accepted"] == 0, "a lost reply applies nothing yet and keeps the batch")
	ok(not r._inflight.is_empty(), "unconfirmed batch is held")
	_kill(_robber(shell, Vector3(2, 0, 5)), hero)
	await r.flush()   # re-sends batch 1 with the SAME number: backend says duplicate
	ok(r.batch_no == 1 and r._inflight.is_empty(), "the retry reuses the batch number and is acknowledged as duplicate")
	var v: DmResult = await u[0].session_get(r.session_id)
	ok(v.data["members"][0]["acceptedKills"] == 3 and v.data["lastBatch"] == 1, "no double credit from the retry", str(v.data))
	ok(m.stats["kills_accepted"] == 3, "the lost batch's credit is recovered once from the backend counters, not lost or doubled", str(m.stats))
	await r.flush()   # the 4th kill goes out as batch 2
	v = await u[0].session_get(r.session_id)
	ok(r.batch_no == 2 and v.data["members"][0]["acceptedKills"] == 4, "later kills ride the next batch number", str(v.data))
	# late/old batch numbers from elsewhere
	var late: DmResult = await u[0].session_report(r.session_id, 1, [{"characterId": u[1], "groups": [{"area": "graves", "def": "robber", "level": 1, "elite": false, "tier": 0, "diff": "medium", "rank": 0, "xpMult": 1, "goldMult": 1, "shardMult": 1, "n": 5}], "bosses": []}])
	ok(late.ok and late.data.get("duplicate", false), "a late/old batch number is ignored by the backend")
	# partial acceptance: the backend takes half; XP and kills scale to what it accepted
	for i in 4:
		_kill(_robber(shell, Vector3(2, 0, 7 + i)), hero)
	var xp0: int = m.stats["xp_applied"]
	var pending: float = m.pending_xp
	wire.halve_next_report = true
	await r.flush()
	ok(m.stats["kills_accepted"] == 4 + 2, "only the accepted share of kills is applied", str(m.stats))
	ok(m.stats["xp_applied"] - xp0 == DmMath.js_round(pending * 0.5), "xp follows the accepted share", str([m.stats["xp_applied"] - xp0, pending]))
	await r.end_session()
	shell.queue_free()
	r.queue_free()


# ---------------------------------------------------------------------------------------------------------------- refusals

func _t_refusals() -> void:
	var mock := DmOffline.make_mock("")
	mock.now_ms = func(): return _clock[0]
	var ua = await _user(mock, "hostr")
	var ub = await _user(mock, "member")
	var uc = await _user(mock, "outsider")
	var shell := Shell.new()
	root.add_child(shell)
	var r := _new_rewards(shell)
	var a_body := _body(Vector3.ZERO)
	var a := DmRewardsMember.make(ua[1], 1, a_body, ua[0])
	var b := DmRewardsMember.make(ub[1], 2, _body(Vector3(3, 0, 0)), ub[0])
	# the "outsider" claims a character it does not own (host's character id with its own API): the join is refused
	var bad := DmRewardsMember.make(ua[1] + 1000, 3, _body(Vector3(4, 0, 0)), uc[0])
	r.add_member(a)
	r.add_member(b)
	r.add_member(bad)
	var refused := []
	r.member_refused.connect(func(cid, reason): refused.append([cid, reason]))
	await r.start(ua[1])
	ok(bad.blocked == "join_refused", "a member whose join is refused earns nothing", bad.blocked)
	for i in 3:
		_kill(_robber(shell, Vector3(2, 0, i)), a_body)
	ok(bad.stats["kills_earned"] == 0 and b.stats["kills_earned"] == 3, "blocked members are skipped, others earn")
	# bob goes quiet: stale heartbeat
	_clock[0] += DmOfflineSessions.HEARTBEAT_TTL_MS + 1000
	await r.flush()
	ok(a.stats["kills_accepted"] == 3, "the host member is credited")
	ok(b.stats["kills_accepted"] == 0 and b.stats["xp_applied"] == 0 and b.last_refusal == "stale_heartbeat" and b.blocked == "", "stale member refused gracefully, not blocked", str(refused))
	var got_sig := false
	for x in refused:
		if x[0] == ub[1] and x[1] == "stale_heartbeat":
			got_sig = true
	ok(got_sig, "member_refused signal fired")
	# bob heartbeats again, then leaves: refused as left and blocked from then on
	await ub[0].session_heartbeat(r.session_id, ub[1], 3)
	_kill(_robber(shell, Vector3(2, 0, 9)), a_body)
	await r.flush()
	ok(b.stats["kills_accepted"] == 1, "credited again after a heartbeat")
	await ub[0].session_leave(r.session_id, ub[1])
	_kill(_robber(shell, Vector3(2, 0, 10)), a_body)
	await r.flush()
	ok(b.blocked == "left" and b.stats["kills_accepted"] == 1, "a member that left is refused and blocked", b.blocked)
	var n: int = b.stats["kills_earned"]
	_kill(_robber(shell, Vector3(2, 0, 11)), a_body)
	ok(b.stats["kills_earned"] == n, "no further rewards for a blocked member")
	# host-only reporting: a member's API cannot report
	var imp: DmResult = await ub[0].session_report(r.session_id, 99, [{"characterId": ub[1], "groups": [], "bosses": []}])
	ok(not imp.ok, "only the host's api can report")
	await r.end_session()
	shell.queue_free()
	r.queue_free()


# ---------------------------------------------------------------------------------------------------------------- end

func _t_end() -> void:
	var mock := DmOffline.make_mock("")
	mock.now_ms = func(): return _clock[0]
	var u = await _user(mock, "ender")
	var shell := Shell.new()
	root.add_child(shell)
	var r := _new_rewards(shell)
	var hero := _body(Vector3.ZERO)
	var m := DmRewardsMember.make(u[1], 1, hero, u[0])
	r.add_member(m)
	await r.start(u[1])
	for i in 2:
		_kill(_robber(shell, Vector3(2, 0, i)), hero)
	var closed := []
	r.session_closed.connect(func(): closed.append(true))
	await r.end_session({"seconds": 60})
	ok(closed.size() == 1 and m.stats["kills_accepted"] == 2, "end carries a final batch that is credited", str(m.stats))
	var v: DmResult = await u[0].session_get(r.session_id)
	ok(v.ok and v.data["status"] == "ended" and v.data["members"][0]["acceptedKills"] == 2, "backend session ended with the kills counted", str(v.data))
	_kill(_robber(shell, Vector3(2, 0, 4)), hero)
	ok(m.stats["kills_earned"] == 2, "no rewards after the session ended")
	await r.end_session()
	ok(true, "ending twice is harmless")
	var rep: DmResult = await u[0].session_report(r.session_id, 50, [{"characterId": u[1], "groups": [], "bosses": []}])
	ok(not rep.ok, "reports after the end are refused")
	# a session that cannot open (no backend): the node degrades without crashing
	var r2 := _new_rewards(shell)
	var dead_api := DmApi.new(Callable())
	var m2 := DmRewardsMember.make(7, 1, hero, dead_api)
	r2.add_member(m2)
	var failed := []
	r2.session_failed.connect(func(why): failed.append(why))
	ok(not await r2.start(7) and failed.size() == 1, "an unreachable backend fails the open gracefully")
	r2.on_kill({"def": "robber", "area": "graves", "level": 1, "elite": false, "x": 1.0, "z": 0.0, "killer": hero})
	await r2.flush()
	ok(m2.prog.local["totalKills"] == 0, "nothing is applied without a backend session (D1)")
	shell.queue_free()
	r.queue_free()
