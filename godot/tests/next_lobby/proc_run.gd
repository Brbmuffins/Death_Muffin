extends SceneTree
## Party over the real relay with SEPARATE processes: the local lobby service (node) + a host game and a joiner game, each a full DmMain in its own
## headless Godot (tests/next_lobby/proc_main.gd), driven through files.   godot --headless --path godot --script res://tests/next_lobby/proc_run.gd
## solo -> host -> list -> join by id (the solo game is swapped for a client game) -> both see both -> movement + chat -> joiner leaves (back to solo) ->
## private host -> join by code -> the host process is killed (the joiner is sent home) -> a joiner process is killed (the host is clean) -> the cost.
## Each process has its own offline backend, so the joiner's backend join is refused: asserted (the credit path itself is tests/next_lobby/run.gd).

var passed := 0
var failed := 0
var lobby: DmTestLobby
var dir := ""
var pids: Dictionary = {}
var seqs: Dictionary = {}
var killed := ""


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String, extra: String = "") -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what, " ", extra)


func status(nm: String) -> Dictionary:
	var p := dir.path_join("status_%s.json" % nm)
	if not FileAccess.file_exists(p):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return v if typeof(v) == TYPE_DICTIONARY else {}


func cmd(nm: String, c: Dictionary) -> void:
	seqs[nm] = int(seqs.get(nm, 0)) + 1
	c["seq"] = seqs[nm]
	var f := FileAccess.open(dir.path_join("cmd_%s.json" % nm), FileAccess.WRITE)
	f.store_string(JSON.stringify(c))
	f.close()


func wait_for(cond: Callable, limit_s: float = 20.0) -> bool:
	var end := Time.get_ticks_msec() + int(limit_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await create_timer(0.1).timeout
	return cond.call()


func spawn(role: String, nm: String, account: int) -> void:
	OS.set_environment("DM_LOBBY_TOKEN", lobby.token(account, nm))
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/next_lobby/proc_main.gd", "--",
		role, dir, nm, "--next", "--class=2", "--lobby=" + lobby.url]
	pids[nm] = OS.create_process(OS.get_executable_path(), args)


func in_world(nm: String) -> bool:
	var s := status(nm)
	return bool(s.get("ready", false)) and s.has("mode")


func _finish() -> void:
	for nm in pids:
		if nm != killed and OS.is_process_running(int(pids[nm])):
			OS.kill(int(pids[nm]))
	if lobby != null:
		lobby.stop()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _run() -> void:
	lobby = DmTestLobby.start()
	if lobby == null:
		print("next_lobby proc: SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm install`)")
		print("0 passed, 0 failed (skipped)")
		quit(0)
		return
	dir = OS.get_user_data_dir().path_join("party_proc_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(dir)
	check(await lobby.wait_ready(self), "the local lobby service is up")
	spawn("host", "hostp", 301)
	check(await wait_for(func() -> bool: return in_world("hostp"), 150.0), "host process: in the world, solo", str(status("hostp")))
	var h := status("hostp")
	check(h.get("mode", "") == "solo" and bool(h.get("hud", false)) and not h.has("out"), "solo: no lobby traffic, a HUD, mode solo")
	spawn("joiner", "joinerp", 302)
	check(await wait_for(func() -> bool: return in_world("joinerp"), 150.0), "joiner process: in its own world, solo")
	var slice0 := int(status("joinerp")["slice"])

	# host a public session, the joiner sees it in its list and joins it
	cmd("hostp", {"cmd": "host", "name": "Proc Crypt", "private": false})
	check(await wait_for(func() -> bool: return status("hostp").get("mode", "") == "host", 15.0), "host: hosting (solo became a session)", str(status("hostp")))
	cmd("joinerp", {"cmd": "list"})
	check(await wait_for(func() -> bool: return status("joinerp").get("sessions", []).size() == 1, 15.0), "joiner: the public list shows the session", str(status("joinerp").get("sessions")))
	var row: Dictionary = status("joinerp")["sessions"][0]
	check(row["name"] == "Proc Crypt" and row["host"] == "hostp" and int(row["players"]) == 1 and int(row["max"]) == 4, "joiner: name, host, players x/4 in the row", str(row))
	cmd("joinerp", {"cmd": "join_id", "id": row["id"]})
	check(await wait_for(func() -> bool:
		var j := status("joinerp")
		return j.get("mode", "") == "client" and int(j.get("slice", 0)) != slice0 and bool(j.get("ready", false)) and j.get("roster", []).size() == 2, 150.0), "joiner: the solo game was swapped for a client game and sees both players", str(status("joinerp")))
	check(await wait_for(func() -> bool: return status("hostp").get("roster", []).size() == 2 and status("hostp").get("bodies", {}).size() == 2, 20.0), "host: sees both players")
	var j := status("joinerp")
	check(bool(j.get("hud", false)), "joiner: has a HUD in the client game")
	check(j["my_id"] == 2 and j["bodies"].has("1") and j["bodies"].has("2"), "joiner: peer id 2, both bodies present")
	# the joiner's own backend is a different one: the host's session is unknown to it
	check(await wait_for(func() -> bool:
		var mem: Dictionary = status("hostp").get("members", {})
		for k in mem:
			if mem[k]["remote"] and mem[k]["blocked"] == "join_refused":
				return true
		return false, 20.0), "host: the joiner's backend join was refused (its own backend), so it is not credited", str(status("hostp").get("members")))
	check(await wait_for(func() -> bool: return status("joinerp").get("toasts", []).any(func(t: String) -> bool: return t.contains("will not be credited")), 10.0), "joiner: is told its kills will not be credited", str(status("joinerp").get("toasts")))

	# movement: the joiner's intent moves its body on the host and the host's snapshot brings it back
	var p0: Array = status("hostp")["bodies"]["2"]
	cmd("joinerp", {"cmd": "move", "x": p0[0] + 5.0, "z": p0[1] + 2.0})
	check(await wait_for(func() -> bool:
		var b: Array = status("hostp")["bodies"]["2"]
		return Vector2(b[0] - p0[0], b[1] - p0[1]).length() > 2.5, 15.0), "movement: the joiner's body walked on the host")
	check(await wait_for(func() -> bool:
		var hb: Array = status("hostp")["bodies"]["2"]
		var jb: Array = status("joinerp")["bodies"]["2"]
		return Vector2(hb[0] - jb[0], hb[1] - jb[1]).length() < 1.5, 15.0), "movement: and the joiner's own picture agrees with the host")
	cmd("joinerp", {"cmd": "chat", "text": "hello over the relay"})
	check(await wait_for(func() -> bool: return status("hostp").get("chat", []).any(func(l: String) -> bool: return l.ends_with("hello over the relay")), 10.0), "chat: the joiner's line reached the host")

	# the cost of a hosted session: idle, then with 25 enemies on the field
	var a := status("hostp")
	await create_timer(5.0).timeout
	var b := status("hostp")
	var idle_bps := float(int(b["out"]) - int(a["out"])) / 5.0
	var idle_pps := float(int(b["pout"]) - int(a["pout"])) / 5.0
	cmd("hostp", {"cmd": "spawn", "n": 25})
	check(await wait_for(func() -> bool: return int(status("hostp").get("enemies", 0)) >= 20, 15.0), "cost: 25 enemies stand on the host", "enemies=%s" % status("hostp").get("enemies"))
	a = status("hostp")
	var ja := status("joinerp")
	await create_timer(5.0).timeout
	b = status("hostp")
	var jb2 := status("joinerp")
	var load_bps := float(int(b["out"]) - int(a["out"])) / 5.0
	var load_pps := float(int(b["pout"]) - int(a["pout"])) / 5.0
	var in_bps := float(int(jb2["in"]) - int(ja["in"])) / 5.0
	print("COST hosted session, 1 joiner: idle host->relay %.1f KB/s %.0f packets/s; 25 enemies %.1f KB/s %.0f packets/s (joiner receives %.1f KB/s); host fps %.0f" % [idle_bps / 1024.0, idle_pps, load_bps / 1024.0, load_pps, in_bps / 1024.0, float(b.get("fps", 0))])
	check(load_pps < 400.0 and load_bps < 300.0 * 1024.0, "cost: under load the host sends < 400 packets/s and < 300 KB/s (relay limits 600/s, 1 MiB/s)")
	check(idle_pps < 200.0, "cost: idle hosted session < 200 packets/s")

	# the joiner leaves through its window's call: back to its own world, solo
	var slice1 := int(status("joinerp")["slice"])
	cmd("joinerp", {"cmd": "leave"})
	check(await wait_for(func() -> bool:
		var jj := status("joinerp")
		return jj.get("mode", "") == "solo" and int(jj.get("slice", 0)) != slice1 and bool(jj.get("ready", false)), 150.0), "leave: the joiner is back in its own solo world", str(status("joinerp")))
	check(await wait_for(func() -> bool: return status("hostp").get("roster", []).size() == 1, 15.0), "leave: the host is alone and still hosting", str(status("hostp")))
	check(status("hostp").get("mode", "") == "host", "leave: host mode kept")

	# private: a code, join by code, then the host process dies
	cmd("hostp", {"cmd": "leave"})
	check(await wait_for(func() -> bool: return status("hostp").get("mode", "") == "solo", 10.0), "host: leaves its session, plays on solo")
	cmd("hostp", {"cmd": "host", "name": "Secret Crypt", "private": true})
	check(await wait_for(func() -> bool: return String(status("hostp").get("code", "")).length() == 6, 15.0), "private: a six-digit code")
	var code := String(status("hostp")["code"])
	var slice2 := int(status("joinerp")["slice"])
	cmd("joinerp", {"cmd": "join_code", "code": "000000" if code != "000000" else "111111"})
	check(await wait_for(func() -> bool: return status("joinerp").get("err", {}).get("code", "") == "bad_code", 15.0), "private: a wrong code is bad_code in the joiner's state", str(status("joinerp").get("err")))
	cmd("joinerp", {"cmd": "join_code", "code": code})
	check(await wait_for(func() -> bool:
		var jj := status("joinerp")
		return jj.get("mode", "") == "client" and int(jj.get("slice", 0)) != slice2 and bool(jj.get("ready", false)), 150.0), "private: joined by code", str(status("joinerp")))
	await wait_for(func() -> bool: return status("hostp").get("roster", []).size() == 2, 20.0)
	var slice3 := int(status("joinerp")["slice"])
	var swaps := int(status("joinerp")["swaps"])
	killed = "hostp"
	OS.kill(int(pids["hostp"]))   # the host's machine dies
	check(await wait_for(func() -> bool:
		var jj := status("joinerp")
		return jj.get("mode", "") == "solo" and int(jj.get("slice", 0)) != slice3 and bool(jj.get("ready", false)) and int(jj.get("swaps", 0)) > swaps, 150.0), "host death: the joiner is back in its own world, solo", str(status("joinerp")))
	check(status("joinerp").get("toasts", []).any(func(t: String) -> bool: return t.contains("host ended") or t.contains("Lost the connection")), "host death: with the reason on screen", str(status("joinerp").get("toasts")))
	_finish()
