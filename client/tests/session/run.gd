extends SceneTree
## DmSession tests. Run: godot --headless --path client --script res://tests/session/run.gd
## Part A: in-process (5 SceneMultiplayer branches in one tree). Part B: host + clients as REAL separate processes over ENet.
## Ports: a free random UDP port per run on 127.0.0.1 (several worktrees run this suite at once; fixed ports made them steal each
## other's ports, and user:// — shared by every worktree — keyed the command folder by port). Never the production 5190/5191.

var PORT_INPROC := 0
var PORT_PROC := 0
var passed := 0
var failed := 0
var pids: Array = []


func ok(c: bool, msg: String) -> void:
	if c:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", msg)


func _initialize() -> void:
	_main()


func _main() -> void:
	await process_frame
	PORT_INPROC = DmTestPorts.free_port()
	PORT_PROC = DmTestPorts.free_port(PORT_INPROC)
	ok(PORT_INPROC > 0 and PORT_PROC > 0, "free test ports found (%d, %d)" % [PORT_INPROC, PORT_PROC])
	_phase_point()
	await _part_a()
	await _part_b()
	await _part_c()
	for p in pids:
		OS.kill(p)
	print("%d passed, %d failed" % [passed, failed])
	print("%s session %d checks%s" % ["PASS" if failed == 0 else "FAIL", passed + failed, "" if failed == 0 else " (%d failed)" % failed])
	quit(1 if failed > 0 else 0)


## A body with a 1 m prop hole at x 2..3 (a detour of a metre) and a wall at x 6..6.5 (a 30 m detour).
class PropBody:
	extends DmSessionBody

	func walkable(pt: Vector3) -> bool:
		return not (pt.x >= 2.0 and pt.x <= 3.0) and not (pt.x >= 6.0 and pt.x <= 6.5)

	func path_len(a: Vector3, b: Vector3) -> float:
		var d := a.distance_to(b)
		return d + 30.0 if (a.x < 6.0 and b.x > 6.5) else d + (1.0 if (a.x < 2.0 and b.x > 3.0) else 0.0)


func _phase_point() -> void:
	var b := PropBody.new()
	var p := b.phase_point(Vector3(5.0, 0, 0))
	ok(absf(p.x - 5.0) < 0.01, "phase_point slips past a prop hole to the far end (%s)" % str(p))
	ok(b.dash_point(Vector3(5.0, 0, 0)).x < 2.0, "dash_point still stops at the same hole (veil step is unchanged)")
	p = b.phase_point(Vector3(9.0, 0, 0))
	ok(p.x < 6.0 and p.x > 5.5, "phase_point stops at a wall, not beyond it (%s)" % str(p))
	b.dash(Vector3(8, 0, 0), 1.0, false)
	b._step_dash(0.25)
	ok(absf(b.position.x - 2.0) < 0.01, "an even dash covers a quarter of the way in a quarter of the time (%.2f)" % b.position.x)
	b.free()


func wait_for(cond: Callable, timeout := 8.0) -> bool:
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < timeout * 1000.0:
		if cond.call():
			return true
		await create_timer(0.05).timeout
	return cond.call()


# ---------------- Part A: in-process ----------------

class Probe:
	var started := false
	var ended := ""
	var joined: Array = []
	var left: Array = []


func _mk(nm: String, cls: Variant = null) -> Array:
	var h := Node.new()
	h.name = nm
	root.add_child(h)
	var s: DmSession = cls.new() if cls != null else DmSession.new()
	s.name = "Session"
	h.add_child(s)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/" + nm))
	var p := Probe.new()
	s.session_started.connect(func(): p.started = true)
	s.session_ended.connect(func(r): p.ended = r)
	s.player_joined.connect(func(id): p.joined.append(id))
	s.player_left.connect(func(id): p.left.append(id))
	s.character_name = nm
	s.discipline_id = "d_" + nm
	return [s, p]


func _client(s: DmSession) -> void:
	var peer := ENetMultiplayerPeer.new()
	peer.create_client("127.0.0.1", PORT_INPROC)
	s.join(peer)


func _part_a() -> void:
	var h := _mk("H")
	var hs: DmSession = h[0]
	var hp: Probe = h[1]
	var hpeer := ENetMultiplayerPeer.new()
	ok(hpeer.create_server(PORT_INPROC, 8) == OK, "A: server created")
	ok(hs.host(hpeer) == OK, "A: host() ok")
	ok(hp.started and hs.get_roster().size() == 1, "A: host session_started + roster of 1")
	var cs: Array = []
	for n in ["C1", "C2", "C3"]:
		var c := _mk(n)
		cs.append(c)
		_client(c[0])
	ok(await wait_for(func(): return cs.all(func(c): return c[1].started)), "A: 3 clients started")
	ok(await wait_for(func(): return hs.get_bodies().size() == 4 and cs.all(func(c): return c[0].get_bodies().size() == 4)), "A: 4 bodies everywhere")
	var rh := hs.get_roster()
	ok(rh.size() == 4, "A: host roster 4")
	for c in cs:
		ok(c[0].get_roster() == rh, "A: client roster equals host roster")
	var e1: Dictionary = rh.filter(func(e): return e["name"] == "C1")[0]
	ok(e1["discipline"] == "d_C1" and e1["peer_id"] == (cs[0][0] as DmSession).get_my_id(), "A: roster carries name + discipline + id")
	ok(hp.joined.size() == 4 and (cs[0][1] as Probe).joined.size() == 4, "A: player_joined fired for everyone")
	# movement
	(cs[0][0] as DmSession).request_move_to(Vector3(6, 0, 2))
	(cs[1][0] as DmSession).request_move_to(Vector3(-5, 0, 4))
	var id1: int = (cs[0][0] as DmSession).get_my_id()
	var id2: int = (cs[1][0] as DmSession).get_my_id()
	ok(await wait_for(func(): return hs.get_body(id1).position.distance_to(Vector3(6, 0, 2)) < 0.01 and hs.get_body(id2).position.distance_to(Vector3(-5, 0, 4)) < 0.01), "A: host bodies reach targets")
	var converged := func() -> bool:
		for c in cs:
			for id in [id1, id2]:
				if (c[0] as DmSession).get_body(id).position.distance_to(hs.get_body(id).position) >= 0.05:
					return false
		return true
	ok(await wait_for(converged), "A: clients converge on host positions")
	# speed clamp: 10 units in <= ~2s at 5 u/s means not instant
	var p0 := hs.get_body(id1).position
	(cs[0][0] as DmSession).request_move_to(Vector3(-30, 0, 2))
	await create_timer(0.5).timeout
	ok(hs.get_body(id1).position.distance_to(p0) < 5.0 * 0.5 + 0.3, "A: host clamps speed")
	(cs[0][0] as DmSession).request_move_to(Vector3(1e9, 0, 0))
	(cs[0][0] as DmSession).request_move_to(Vector3(INF, 0, 0))
	ok(await wait_for(func(): return hs.rejected_intents >= 1), "A: non-finite intent rejected")
	# forged intent
	var before := hs.get_body(id2).position
	var rej := hs.rejected_intents
	(cs[0][0] as DmSession).request_move_to(Vector3(20, 0, 20), id2)
	await wait_for(func(): return hs.rejected_intents > rej)
	ok(hs.rejected_intents == rej + 1 and hs.get_body(id2).position.distance_to(before) < 0.001, "A: forged intent for another body ignored")
	# dir intent + ttl
	var pd := hs.get_body(id2).position
	(cs[1][0] as DmSession).request_move_dir(Vector3(1, 0, 0))
	await create_timer(0.6).timeout
	var moved := hs.get_body(id2).position.x - pd.x
	ok(moved > 0.1 and moved < 1.5, "A: dir intent moves then expires without resend (moved %.2f)" % moved)
	# full session: 5th player
	var c4 := _mk("C4")
	_client(c4[0])
	ok(await wait_for(func(): return (c4[1] as Probe).ended != ""), "A: 5th joiner got session_ended")
	ok("full" in (c4[1] as Probe).ended, "A: refusal reason mentions full: '%s'" % (c4[1] as Probe).ended)
	ok(not (c4[1] as Probe).started, "A: refused joiner never started")
	ok(hs.get_roster().size() == 4, "A: roster still 4 after refusal")
	# disconnect despawn
	var gone_id: int = (cs[2][0] as DmSession).get_my_id()
	(cs[2][0] as DmSession).leave()
	ok(await wait_for(func(): return hs.get_body(gone_id) == null and (cs[0][0] as DmSession).get_body(gone_id) == null and (cs[1][0] as DmSession).get_body(gone_id) == null), "A: leaver despawned everywhere")
	ok(gone_id in hp.left and gone_id in (cs[0][1] as Probe).left, "A: player_left fired on host and peers")
	# builds: a different release build is refused with the fix in the reason; an old protocol-1 client (3-argument hello) too; dev plays
	hs.build_version = "20261015.020000-1234567"
	var cv := _mk("CV")
	(cv[0] as DmSession).build_version = "20261015.010000-abcdef0"
	_client(cv[0])
	ok(await wait_for(func(): return (cv[1] as Probe).ended != ""), "A: older build got session_ended")
	ok("newer version" in (cv[1] as Probe).ended and "launcher" in (cv[1] as Probe).ended, "A: build refusal says how to fix it: '%s'" % (cv[1] as Probe).ended)
	ok(not (cv[1] as Probe).started and hs.get_roster().size() == 3, "A: older build never started, roster unchanged")
	var co := _mk("CO", OldHello)
	_client(co[0])
	ok(await wait_for(func(): return (co[1] as Probe).ended != ""), "A: protocol-1 client got session_ended")
	ok("newer version" in (co[1] as Probe).ended, "A: protocol-1 client hears the host is newer: '%s'" % (co[1] as Probe).ended)
	var cd := _mk("CD")
	(cd[0] as DmSession).build_version = "dev"
	_client(cd[0])
	ok(await wait_for(func(): return (cd[1] as Probe).started), "A: a dev build still joins a release host")
	(cd[0] as DmSession).leave()
	ok(await wait_for(func(): return hs.get_roster().size() == 3), "A: dev joiner left")
	hs.build_version = ""
	ok(hs.get_roster().size() == 3 and (cs[0][0] as DmSession).get_roster().size() == 3, "A: rosters shrink to 3")
	# host leaves
	hs.leave()
	ok(await wait_for(func(): return (cs[0][1] as Probe).ended != "" and (cs[1][1] as Probe).ended != ""), "A: clients ended when host left")
	ok("host" in (cs[0][1] as Probe).ended, "A: host-left reason: '%s'" % (cs[0][1] as Probe).ended)
	ok(not (cs[0][0] as DmSession).is_active(), "A: client session idle after end")
	for n in ["H", "C1", "C2", "C3", "C4"]:
		root.get_node(n).queue_free()
	await create_timer(0.2).timeout


# ---------------- Part B: separate processes ----------------

var dir := ""
var seqs := {}


func spawn(role: String, nm: String) -> void:
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/session/peer_proc.gd",
			"--", role, str(PORT_PROC), dir, nm])
	var pid := OS.create_process(OS.get_executable_path(), args)
	ok(pid > 0, "B: spawned %s" % nm)
	pids.append(pid)
	return


func cmd(nm: String, d: Dictionary) -> void:
	seqs[nm] = int(seqs.get(nm, 0)) + 1
	d["seq"] = seqs[nm]
	var f := FileAccess.open("%s/cmd_%s.json" % [dir, nm], FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


func st(nm: String) -> Dictionary:
	var p := "%s/status_%s.json" % [dir, nm]
	if not FileAccess.file_exists(p):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return v if typeof(v) == TYPE_DICTIONARY else {}


func near(a: Array, b: Array) -> bool:
	return absf(a[0] - b[0]) < 0.05 and absf(a[1] - b[1]) < 0.05


func _part_b() -> void:
	dir = ProjectSettings.globalize_path("user://session_test_%d" % PORT_PROC)
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	spawn("host", "host")
	await wait_for(func(): return bool(st("host").get("started", false)), 30.0)
	spawn("client", "A")
	spawn("client", "B")
	var all3 := func():
		for n in ["host", "A", "B"]:
			var s := st(n)
			if s.is_empty() or (s["roster"] as Array).size() != 3 or (s["bodies"] as Dictionary).size() != 3:
				return false
		return true
	ok(await wait_for(all3, 20.0), "B: host + 2 client processes all see 3 players")
	var rh: Array = st("host").get("roster_full", [])
	ok(st("A").get("roster_full") == rh and st("B").get("roster_full") == rh, "B: identical roster in all 3 processes")
	var names := []
	for e in rh:
		names.append(e["name"])
	names.sort()
	ok(names == ["A", "B", "host"], "B: roster names %s" % str(names))
	var ida: int = int(st("A")["my_id"])
	var idb: int = int(st("B")["my_id"])
	ok(ida != idb and ida > 1 and idb > 1, "B: distinct peer ids")
	cmd("A", {"cmd": "move", "x": 7.0, "z": -3.0})
	cmd("B", {"cmd": "move", "x": -6.0, "z": 5.0})
	var conv := func():
		var h: Dictionary = st("host").get("bodies", {})
		if h.is_empty() or not h.has(str(ida)) or not h.has(str(idb)):
			return false
		if not (near(h[str(ida)], [7, -3]) and near(h[str(idb)], [-6, 5])):
			return false
		for n in ["A", "B"]:
			var b: Dictionary = st(n).get("bodies", {})
			if not b.has(str(ida)) or not b.has(str(idb)) or not near(b[str(ida)], h[str(ida)]) or not near(b[str(idb)], h[str(idb)]):
				return false
		return true
	ok(await wait_for(conv, 15.0), "B: all processes converge on host positions after both clients move")
	# forged intent: A tries to move B's body
	var rej0 := int(st("host").get("rejected", 0))
	var bpos: Array = st("host")["bodies"][str(idb)]
	cmd("A", {"cmd": "move", "x": 0.0, "z": 0.0, "body": idb})
	ok(await wait_for(func(): return int(st("host").get("rejected", 0)) > rej0, 5.0), "B: host rejected the forged intent")
	await create_timer(0.8).timeout
	ok(near(st("host")["bodies"][str(idb)], bpos), "B: B's body did not move after A's forged intent")
	# 3rd client fills the session, 4th is refused
	spawn("client", "C")
	ok(await wait_for(func(): return (st("C").get("roster", []) as Array).size() == 4 and (st("host").get("roster", []) as Array).size() == 4, 15.0), "B: third client joins (4/4)")
	spawn("client", "D")
	ok(await wait_for(func(): return str(st("D").get("ended", "")) != "", 15.0), "B: 5th joiner refused")
	ok("full" in str(st("D").get("ended", "")), "B: refusal reason '%s'" % str(st("D").get("ended", "")))
	ok(not bool(st("D").get("started", true)), "B: refused joiner never started")
	ok((st("host")["roster"] as Array).size() == 4, "B: host roster still 4")
	cmd("D", {"cmd": "quit"})
	# C leaves -> despawn everywhere
	var idc: int = int(st("C")["my_id"])
	cmd("C", {"cmd": "quit"})
	var gone := func():
		for n in ["host", "A", "B"]:
			var s := st(n)
			if (s.get("bodies", {}) as Dictionary).has(str(idc)) or (s.get("roster", []) as Array).size() != 3:
				return false
		return true
	ok(await wait_for(gone, 15.0), "B: disconnected client's body despawned in host, A and B")
	ok(("left:%d" % idc) in st("A")["events"] and ("left:%d" % idc) in st("host")["events"], "B: player_left event delivered")
	# host leaves
	cmd("host", {"cmd": "leave"})
	ok(await wait_for(func(): return str(st("A").get("ended", "")) != "" and str(st("B").get("ended", "")) != "", 15.0), "B: clients ended when host left")
	ok("host" in str(st("A").get("ended", "")), "B: host-left reason '%s'" % str(st("A").get("ended", "")))
	for n in ["host", "A", "B", "C", "D"]:
		cmd(n, {"cmd": "quit"})
	await create_timer(1.0).timeout
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	DirAccess.remove_absolute(dir)


# ---------------- Part C: solo = 1-player session, no network ----------------

func _part_c() -> void:
	var h := Node.new()
	h.name = "Solo"
	root.add_child(h)
	var s := DmSession.new()
	s.name = "Session"
	h.add_child(s)
	s.character_name = "Solo"
	s.discipline_id = "d_solo"
	var started := [false]
	var ended := [""]
	s.session_started.connect(func(): started[0] = true)
	s.session_ended.connect(func(r): ended[0] = r)
	var peer := OfflineMultiplayerPeer.new()
	ok(s.host(peer) == OK, "C: host(OfflineMultiplayerPeer) ok")
	ok(started[0] and s.is_host() and s.get_my_id() == 1, "C: solo session started as peer 1")
	ok(s.get_roster().size() == 1 and s.get_body(1) != null, "C: own body spawned through the normal path")
	s.request_move_to(Vector3(4, 0, -2))
	ok(await wait_for(func(): return s.get_body(1).position.distance_to(Vector3(4, 0, -2)) < 0.01), "C: solo body moves via intents")
	s.request_move_dir(Vector3(0, 0, 1))
	ok(await wait_for(func(): return s.get_body(1).position.z > -2.0 + 0.5), "C: dir intent works solo")
	ok(s.rejected_intents == 0, "C: no intents rejected")
	await s.leave()
	ok(ended[0] != "" and not s.is_active(), "C: solo session ends cleanly")
	h.queue_free()


## A protocol-1 client (before builds were checked): its hello has three arguments.
class OldHello extends DmSession:
	func _on_connected_to_server() -> void:
		_rpc_hello.rpc_id(1, 1, character_name, discipline_id)

