extends "res://tests/common/dm_suite_part.gd"
## Party-session API against the offline backend (decision D4): the same calls a host/member makes online, answered locally.
## Headless:  godot --headless --path godot --script res://tests/backend/run.gd

var _p := 0
var _f := 0
var _clock := [1_790_000_000_000]

func ok(cond: bool, label: String, extra: String = "") -> void:
	if cond:
		_p += 1
	else:
		_f += 1
		print("FAIL: ", label, " ", extra)

func _initialize() -> void:
	await _main()

func _user(mock: DmMockBackend, name: String, class_index: int) -> Array:
	var api := DmOffline.make_api(mock)
	var reg := await api.register(name, "", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(class_index)
	return [api, int(ch.data["id"])]

static func _group(n: int) -> Dictionary:
	return {"area": "graves", "def": "robber", "level": 1, "elite": false, "tier": 0, "diff": "medium", "rank": 0, "xpMult": 1, "goldMult": 1, "shardMult": 1, "n": n}

func _main() -> void:
	var mock := DmOffline.make_mock("")
	mock.now_ms = func(): return _clock[0]
	var h = await _user(mock, "host", 1)
	var m1 = await _user(mock, "friend", 2)
	var m2 = await _user(mock, "stranger", 3)
	var host: DmApi = h[0]
	var friend: DmApi = m1[0]
	var stranger: DmApi = m2[0]
	var hc: int = h[1]
	var fc: int = m1[1]
	var sc: int = m2[1]

	var o := await host.session_open(hc)
	ok(o.ok, "host opens", o.error)
	var sid: String = o.data["sessionId"]
	ok(sid.length() == 32, "session id is 32 hex")
	ok(o.data["members"].size() == 1 and o.data["limits"]["maxMembers"] == 4, "host is member one, party of four")
	ok(not (await stranger.session_open(hc)).ok, "cannot open with someone else's character")
	ok(not (await friend.session_join(sid, sc)).ok, "cannot attach another account's character")
	ok((await friend.session_join(sid, fc)).ok, "member attaches with its own account")
	ok((await friend.session_join(sid, fc)).ok, "joining twice is idempotent")

	var grp := [_group(30)]
	var r := await host.session_report(sid, 1, [{"characterId": hc, "groups": grp, "bosses": []}, {"characterId": fc, "groups": grp, "bosses": []}])
	ok(r.ok and r.data["members"].size() == 2, "host reports a batch", r.error)
	ok(r.ok and r.data["members"][1]["accepted"]["kills"] == 30 and r.data["members"][1]["credited"], "member is credited")
	# outsider never attached
	var r2 := await host.session_report(sid, 2, [{"characterId": sc, "groups": grp, "bosses": []}])
	ok(r2.ok and not r2.data["members"][0]["credited"] and r2.data["members"][0]["reason"] == "not_member", "host cannot credit a non-member")
	# duplicates and older batches
	var r3 := await host.session_report(sid, 2, [{"characterId": fc, "groups": grp, "bosses": []}])
	ok(r3.ok and r3.data.get("duplicate", false) == true, "batch number repeat is ignored")
	var v := await host.session_get(sid)
	ok(v.ok and v.data["members"][1]["acceptedKills"] == 30 and v.data["lastBatch"] == 2, "counters unchanged by the duplicate", str(v.data))
	# only the host reports / ends
	ok(not (await friend.session_report(sid, 9, [{"characterId": fc, "groups": grp, "bosses": []}])).ok, "a member cannot report")
	ok(not (await friend.session_end(sid)).ok, "a member cannot end")
	ok(not (await stranger.session_get(sid)).ok, "a stranger cannot read the session")
	# bounds
	var big := []
	for i in 81:
		big.append(_group(1))
	ok(not (await host.session_report(sid, 3, [{"characterId": fc, "groups": big, "bosses": []}])).ok, "too many groups is refused")
	ok(not (await host.session_report(sid, 0, [{"characterId": fc, "groups": grp, "bosses": []}])).ok, "batch 0 is refused")
	ok(not (await host.session_report(sid, 3, [])).ok, "empty members is refused")
	# presence: the member goes quiet
	_clock[0] += DmOfflineSessions.HEARTBEAT_TTL_MS + 1000
	var r4 := await host.session_report(sid, 3, [{"characterId": fc, "groups": grp, "bosses": []}])
	ok(r4.ok and r4.data["members"][0]["reason"] == "stale_heartbeat", "a silent member is not credited")
	ok((await friend.session_heartbeat(sid, fc, 30)).ok, "heartbeat")
	ok((await friend.session_heartbeat(sid, fc, 30)).data.get("throttled", false), "heartbeat spam is throttled")
	var r5 := await host.session_report(sid, 4, [{"characterId": fc, "groups": grp, "bosses": []}])
	ok(r5.ok and r5.data["members"][0]["credited"], "credited again after the heartbeat")
	# leave
	ok((await friend.session_leave(sid, fc)).ok, "member leaves")
	var r6 := await host.session_report(sid, 5, [{"characterId": fc, "groups": grp, "bosses": []}])
	ok(r6.ok and r6.data["members"][0]["reason"] == "left", "a member that left is not credited")
	ok(not (await friend.session_join(sid, fc)).ok, "cannot rejoin after leaving")
	# end
	var e := await host.session_end(sid, {"batch": 6, "members": [{"characterId": hc, "groups": grp, "bosses": []}]}, {"seconds": 600})
	ok(e.ok and e.data["ended"] and e.data["final"]["members"][0]["accepted"]["kills"] == 30, "end with a final batch", e.error)
	ok((await host.session_end(sid)).data.get("already", false), "ending twice is harmless")
	var r7 := await host.session_report(sid, 7, [{"characterId": hc, "groups": grp, "bosses": []}])
	ok(not r7.ok, "reports after the end are refused")
	ok(not (await stranger.session_join(sid, sc)).ok, "cannot join an ended session")
	# party cap
	var o2 := await host.session_open(hc)
	var sid2: String = o2.data["sessionId"]
	var joined := 0
	for i in 5:
		var u = await _user(mock, "member_%d" % i, 1)
		if (await u[0].session_join(sid2, u[1])).ok:
			joined += 1
	ok(joined == 3, "a session holds four: host plus three", str(joined))

	print("session report tests: %d passed, %d failed" % [_p, _f])
	quit(1 if _f > 0 else 0)
