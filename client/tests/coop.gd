extends SceneTree
## 2-player co-op on the combat core (client/README.md "Co-op on the core"), headless, over a REAL local lobby and relay.
##
## Two game scenes live in this one process, each in its own SceneMultiplayer branch (the way a second machine would be): the HOST (`DmNextGame` hosting) and the GUEST
## (`DmNextGame` joined with `opts.lobby`, a puppet core). The lobby is the real service (server/death-muffin/lobby, node, a random local port, a test JWT secret; needs
## `cd server/death-muffin/lobby && npm ci`, else the suite prints a skip line); the relay is `DmUdpRelay` in this process on a random UDP port, offered by the lobby
## (`DM_RELAY_UDP`), so the game packets travel the UDP lane (ENet) through it. Both are started and stopped by this test (the PID it started, never a pattern).
## Accounts are local: the mock backend in memory, tokens minted here with the lobby's test secret. Nothing leaves this machine (DmConfig allows loopback lobbies and relays only).
##
## Checked, in the order of the run:
##   - the party flow: a wrong code is refused in words; the host makes a Closed party; the guest joins by its code (the solo game is handed over to a guest game as the
##     shell would); an invite and an ask to join, answered, seat a third player;
##   - the connection: a guest game with a puppet core and no director, both on the UDP lane, the hero ids the host gave (the guest's hero is an external of the HOST's core);
##   - the waves: the guest's puppet shows the host's bodies: the live body sets are the same ids and every position is the host's at the snapshot's tick within the wire's
##     1 cm quantization, in a still moment and again in the Full Party's fight; in the fight the counts follow within the send interval;
##   - a guest cast is resolved by the host and its damage shows on both (the hits, the guest's puppet hp, the numbers); a guest's Exhume raises a thrall the host
##     simulates, owned by the guest's hero external, drawn on the guest;
##   - the Gravedigger King wakes for the guest's request and fights both heroes: both are hurt by him, the casts of both and a thrall hurt him, the guest's copy follows him;
##   - a guest-side death shows (vitals, the body, the HUD's veil) and the hero gets up; kills are credited by the HOST only, once each: the guest credits none;
##   - the guest's own account (DECISIONS B22): the host makes it a rewards member (its character, rolling its own drops), it joins the host's backend party session with its own
##     token, the host reads its build from the server; a kill near both pays the guest's XP on its account (the host's accepted report, sent on) and its drops reach it,
##     the items rolled from its own tape; its member, bag, belt and HUD are its own account's;
##   - party chat both ways (the host names the speaker); a piece of gear the guest drops from its Reliquary (found while the host was there) lies on the host's ground,
##     the host picks it up into its own bag and the guest's copy goes;
##   - a version mismatch (the core's wire version, the release build) is refused in the words a player reads, the party is untouched;
##   - the Full Party (72 enemies, 32 thralls, a continuous fight): no packet over 1,392 bytes; the bandwidth and packet rate against the relay's limits (INFO);
##   - a leaving guest leaves a clean host (its legion goes, the collecting stops);
##   - ZERO script errors or engine errors in the log (an OS Logger counts them; warnings are not errors).
## Bakes the robber, the hound and the legionnaire into a scratch folder first (about 25 s). Run (about a minute with --fixed-fps 60):
##   godot --headless --fixed-fps 60 --path client --script res://tests/coop.gd

const OUT := "user://coop_test"
const BAKE := ["grave_robber", "bone_hound", "thrall_legionnaire"]
const SECRET := "coop-test-secret-not-a-real-one"
const PACKET_LIMIT := 1392                 ## today's limit: the most a game packet may hold
const ENET_FREE := 1364                    ## the most ENet sends in one unfragmented datagram (MTU 1,392): the relay's packet (game packet + 6) should stay under it
const RELAY_PACKETS_PER_S := 600           ## the relay's limits per connection (DmUdpRelay.RATE_PACKETS / RATE_BYTES)
const RELAY_BYTES_PER_S := 1048576
const THRALL_BASE := {"warrior": [1.3, 1.0, 5.6], "shieldbearer": [1.3, 1.25, 5.2], "hound": [1.2, 0.7, 7.2], "archer": [7.5, 1.3, 5.4]}
const POS_QUANTUM_BOUND := 0.0072          ## half a centimetre on each axis


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## The relay of the test: the real DmUdpRelay, counting what passes (data packets only, the relay's 6-byte header included) per connection (peer id) and direction.
class TapRelay:
	extends DmUdpRelay
	var tally := {}   ## peer id -> {in_packets, in_bytes, out_packets, out_bytes}
	var max_in := 0
	var max_out := 0

	func _tap(pid: int, dir: String, n: int) -> void:
		var t: Dictionary = tally.get(pid, {"in_packets": 0, "in_bytes": 0, "out_packets": 0, "out_bytes": 0})
		t[dir + "_packets"] += 1
		t[dir + "_bytes"] += n
		tally[pid] = t
		if dir == "in":
			max_in = maxi(max_in, n)
		else:
			max_out = maxi(max_out, n)

	func _receive(p: ENetPacketPeer, data: PackedByteArray, channel: int, now: int) -> void:
		var w: Variant = _who.get(p)
		if w != null and channel != 0 and String(w["sid"]) != "":
			_tap(int(w["pid"]), "in", data.size())
		super(p, data, channel, now)

	func _send(to: ENetPacketPeer, mode: int, data: PackedByteArray) -> void:
		var w: Variant = _who.get(to)
		if w != null:
			_tap(int(w["pid"]), "out", data.size())
		super(to, mode, data)

	func mark() -> Dictionary:
		return tally.duplicate(true)


## Samples the host after each 20 Hz send: the live bodies and where they stood at that snapshot's last tick, so the guest's copy can be compared with the very tick it applied.
class Sampler:
	extends Node
	var game: DmNextGame
	var samples := {}   ## last tick of a frame -> {pos: {id: Vector2}, enemies: Array, thralls: Array, parts: int}
	var _frames := 0
	var _tick := 1

	func _init() -> void:
		process_physics_priority = 200   # after Net (150)

	func _physics_process(_dt: float) -> void:
		var net := game.net
		if int(net.stats["frames"]) == _frames:
			return
		_frames = int(net.stats["frames"])
		var first := _tick
		_tick = int(net._tick)
		var core: RefCounted = game.core_host.core
		var ids: PackedInt32Array = core.enemy_ids()
		var st: PackedInt32Array = core.enemy_states()
		var pp: PackedFloat32Array = core.enemy_positions()
		var s := {"pos": {}, "enemies": [], "thralls": [], "parts": _tick - first}
		for i in ids.size():
			if st[i] != 6:   # DEAD
				s["enemies"].append(ids[i])
				s["pos"][ids[i]] = Vector2(pp[i * 3], pp[i * 3 + 1])
		var tids: PackedInt32Array = core.thrall_ids()
		var tst: PackedInt32Array = core.thrall_states()
		var tp: PackedFloat32Array = core.thrall_positions()
		for i in tids.size():
			if tst[i] != 4:   # T_DEAD
				s["thralls"].append(tids[i])
				s["pos"][tids[i]] = Vector2(tp[i * 3], tp[i * 3 + 1])
		samples[_tick - 1] = s
		if samples.size() > 40:
			samples.erase(samples.keys()[0])


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var lobby_pid := 0
var lobby_url := ""
var relay: TapRelay
var relay_port := 0
var branch_n := 0
var mock: DmMockBackend
var h: DmNextGame                  # the host's game
var g: DmNextGame                  # the guest's game
var hq: Node                       # the host's branch
var gq: Node                       # the guest's branch
var sampler: Sampler
var accounts := {}                 # name -> {id, api, ch}
var hb: DmHeroBody
var gb_h: DmHeroBody               # the guest's body as the HOST has it
var gb_g: DmHeroBody               # the guest's body as the GUEST has it
var kills_host := {}               # killer peer -> kills credited by the host
var credited := {}                 # enemy id -> times credited by the host (must stay 1)
var hurt_by_boss := {1: 0, 2: 0}   # hero peer -> blows of the King that reached it
var last_refusal := ""
var cmp := {"frames": 0, "bodies": 0, "bad": 0, "set_bad": 0, "multi": 0, "lossy": 0}   # compare_sample's running totals
var last_cmp_tick := -1
var kills_guest := 0               # kills credited by the guest (must stay 0)
var died_host := 0                 # enemy_died events on each core
var died_guest := 0
var rng := RandomNumberGenerator.new()


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL coop: " + what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


## Waits (game time: a physics tick is 1/60 s) until `cond` holds, at most `limit_s`.
func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s * 60.0)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func _initialize() -> void:
	_run.call_deferred()


# ------------------------------------------------------------------------------------------------------------------ the service, the accounts, the games

static func _b64url(b: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(b).replace("+", "-").replace("/", "_").replace("=", "")


func token(account_id: int, username: String) -> String:
	var hd := _b64url('{"alg":"HS256","typ":"JWT"}'.to_utf8_buffer())
	var now := int(Time.get_unix_time_from_system())
	var p := _b64url(JSON.stringify({"accountId": account_id, "username": username, "iat": now, "exp": now + 3600}).to_utf8_buffer())
	var sig := Crypto.new().hmac_digest(HashingContext.HASH_SHA256, SECRET.to_utf8_buffer(), (hd + "." + p).to_utf8_buffer())
	return hd + "." + p + "." + _b64url(sig)


func free_port(udp: bool) -> int:
	var r := RandomNumberGenerator.new()
	r.randomize()
	for i in 200:
		var port := r.randi_range(40000, 49999)
		if udp:
			var probe := ENetMultiplayerPeer.new()
			if probe.create_server(port, 1) == OK:
				probe.close()
				return port
		else:
			var tcp := TCPServer.new()
			if tcp.listen(port, "127.0.0.1") == OK:
				tcp.stop()
				return port
	return 0


## The real lobby service on a free local port with the test secret and a friends file (mutual: 101 with 102 and 103), the UDP relay in this process offered through it.
func start_services() -> bool:
	var dir := ProjectSettings.globalize_path("res://").path_join("../server/death-muffin/lobby").simplify_path()
	var out := []
	if OS.execute("node", ["-v"], out) != OK or not FileAccess.file_exists(dir.path_join("node_modules/ws/package.json")):
		printerr("coop: no node or no lobby modules in %s" % dir)
		return false
	var port := free_port(false)
	relay_port = free_port(true)
	if port == 0 or relay_port == 0:
		printerr("coop: no free port")
		return false
	relay = TapRelay.new()
	var rerr := relay.listen(relay_port, "127.0.0.1", SECRET, true)
	if rerr != OK:
		printerr("coop: the relay cannot listen on udp %d (error %d)" % [relay_port, rerr])
		return false
	root.add_child(relay)
	var friends := FileAccess.open(OUT.path_join("friends.json"), FileAccess.WRITE)
	friends.store_string(JSON.stringify({"101": [102, 103], "102": [101], "103": [101]}))
	friends.close()
	OS.set_environment("DM_LOBBY_JWT_SECRET", SECRET)
	OS.set_environment("DM_LOBBY_PORT", str(port))
	OS.set_environment("DM_LOBBY_HOST", "127.0.0.1")
	OS.set_environment("DM_LOBBY_QUIET", "1")
	OS.set_environment("DM_RELAY_UDP", "127.0.0.1:%d" % relay_port)
	OS.set_environment("DM_LOBBY_FRIENDS_FILE", ProjectSettings.globalize_path(OUT.path_join("friends.json")))
	lobby_pid = OS.create_process("node", [dir.path_join("src").path_join("index.js")])
	OS.set_environment("DM_RELAY_UDP", "")
	lobby_url = "ws://127.0.0.1:%d" % port
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 10000:   # real time: under --fixed-fps a game-time timer would run out before node has started
		var c := StreamPeerTCP.new()
		if c.connect_to_host("127.0.0.1", port) == OK:
			for k in 20:
				c.poll()
				if c.get_status() != StreamPeerTCP.STATUS_CONNECTING:
					break
				OS.delay_msec(10)
			var up := c.get_status() == StreamPeerTCP.STATUS_CONNECTED
			c.disconnect_from_host()
			if up:
				return true
		OS.delay_msec(100)
		await process_frame
	return false


func stop_services() -> void:
	if lobby_pid > 0 and OS.is_process_running(lobby_pid):
		OS.kill(lobby_pid)
	lobby_pid = 0
	if relay != null:
		relay.close()


func account(nm: String, id: int, cls: int, level: int) -> void:
	var api := DmOffline.make_api(mock)
	var r := await api.register(nm, "%s@example.com" % nm, "pw1234")
	api.set_token(r.data["token"])
	var c := await api.load_or_create_character(cls)
	DmDevMock.set_level(mock, c.data, level)
	accounts[nm] = {"id": id, "api": api, "ch": c.data}


func new_branch() -> Node:
	branch_n += 1
	var r := Node.new()
	r.name = "Branch%d" % branch_n
	root.add_child(r)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/%s" % r.name))
	return r


func game(br: Node, nm: String, extra: Dictionary = {}) -> DmNextGame:
	var a: Dictionary = accounts[nm]
	var gm: DmNextGame = load("res://next/next_game.tscn").instantiate()
	gm.name = "NextGame"
	br.add_child(gm)
	var o := {"areas": ["graves"], "hud": true, "audio": false, "baked_dir": OUT, "name": nm, "waves": false, "seed": 20261016, "lobby_url": lobby_url, "lobby_token": token(int(a["id"]), nm)}
	o.merge(extra, true)
	gm.start_failed.connect(func(r: String) -> void: last_refusal = r)
	await gm.start(a["ch"], a["api"], o)
	return gm


## What the shell does when the party says join_ready: free the solo game, start a guest game on the same lobby socket.
func hand_over(solo: DmNextGame, br: Node, nm: String, lob: DmLobbyClient, extra: Dictionary = {}) -> DmNextGame:
	await solo.leave()
	solo.queue_free()
	await ticks(2)
	return await game(br, nm, extra.merged({"lobby": lob, "host": false}, true))


func seat(solo: DmNextGame, how: Callable) -> Array:
	var got := [null]
	solo.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: got[0] = [l, i])
	how.call()
	await until(func() -> bool: return got[0] != null or solo.party.last_error.has("code"), 10.0)
	return got[0] if got[0] != null else []


func thrall_stats(kind: String, hp: float, dmg: float) -> Dictionary:
	var b: Array = THRALL_BASE[kind]
	return {"kind": kind, "hp": hp, "maxHp": hp, "damage": dmg, "attackInterval": b[1], "range": b[0], "speed": b[2], "empowered": false, "champion": false, "allyHeal": 0.0}


# ------------------------------------------------------------------------------------------------------------------ the run

func _run() -> void:
	await process_frame
	OS.add_logger(errlog)
	rng.seed = 7
	DirAccess.make_dir_recursive_absolute(OUT)
	if not await start_services():
		stop_services()
		print("coop: SKIPPED (needs `node` and `cd server/death-muffin/lobby && npm ci`, and free ports)")
		print("0 checks (skipped)")
		quit(0)
		return
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug))
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			stop_services()
			quit(1)
			return
	mock = DmOffline.make_mock("")   # memory only: no file, no server
	await account("hostess", 101, 2, 14)
	await account("joiner", 102, 2, 14)
	await account("third", 103, 2, 10)
	await party_flow()
	await connection()
	await party_social()
	await waves_still()
	await casts_and_thralls()
	await the_king()
	await guest_death()
	await guest_account()
	await chat_and_ground()
	await versions()
	await full_party()
	await leaving()
	await finish()


func finish() -> void:
	for gm in [h, g]:
		if gm != null and is_instance_valid(gm):
			gm.process_mode = Node.PROCESS_MODE_DISABLED
	stop_services()
	check(errlog.errors.is_empty(), "zero script errors or engine errors in the log (%d: %s)" % [errlog.errors.size(), "; ".join(errlog.errors.slice(0, 3))])
	if fails == 0:
		print("PASS coop %d checks" % checks)
	else:
		print("FAIL coop: %d of %d checks failed" % [fails, checks])
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ the party flow

func party_flow() -> void:
	hq = new_branch()
	h = await game(hq, "hostess", {"waves": false})
	check(h.ready_ and not h.is_guest and not h.core_host.puppet and h.net != null and h.party != null, "the host's game is up (a solo run, a real core, a Net and a Party node)")
	check(h.party.mode == DmNextParty.SOLO and h.party.online and h.party.unavailable() == "", "solo: online for friends' presence (go_online), and the local lobby may be used")
	hb = h.local_body()
	h.kill_credited.connect(func(id: int, _d: String, _l: int, _e: bool, _a: String, killer: int, _x: float, _z: float) -> void:
		kills_host[killer] = int(kills_host.get(killer, 0)) + 1
		credited[id] = int(credited.get(id, 0)) + 1)
	h.core_host.enemy_died.connect(func(_id: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: died_host += 1)
	sampler = Sampler.new()
	sampler.game = h
	h.add_child(sampler)
	# the live addresses are refused whatever the override says
	var live_lobby := "wss://muffindevelopment.com/death-muffin/lobby/"
	check(not DmConfig.allows_lobby_url(live_lobby) and not DmConfig.allows_lobby_url("ws://example.invalid:5192") and not DmConfig.allows_lobby_url("ws://127.0.0.1@example.invalid:5192/"), "the live lobby and lookalikes are not allowed")
	check(DmConfig.allows_lobby_url(DmConfig.LOBBY_URL) and DmConfig.allows_lobby_url("ws://127.0.0.1:5195") and DmConfig.allows_lobby_url("ws://localhost:41000/x"), "the test lobby and a lobby on this machine are")
	check(not DmConfig.allows_relay("203.0.113.5", 5193) and not DmConfig.allows_relay("127.0.0.1", 5193) and DmConfig.allows_relay("203.0.113.5", DmConfig.RELAY_PORT) and DmConfig.allows_relay("127.0.0.1", relay_port), "a relay on the live port is refused, the test relay's port and this machine are accepted")
	var live := DmNextParty.checked_relay({"addr": "203.0.113.5", "port": 5193, "ticket": "x"})
	check(live.is_empty() and not DmNextParty.checked_relay({"addr": "127.0.0.1", "port": relay_port, "ticket": "x"}).is_empty(), "the party drops a relay offer on the live port and keeps a local one")

	# a third player, solo: errors in words, then the Closed party, an invite and an ask
	var cq := new_branch()
	var c := await game(cq, "third")
	c.party.join_by_code("999999")
	await until(func() -> bool: return c.party.last_error.has("code"), 8.0)
	var code_err := String(c.party.last_error.get("code", ""))
	check((code_err == "bad_code" or code_err == "not_found") and String(c.party.last_error.get("text", "")) == String(DmNextParty.ERROR_TEXT[code_err]), "a wrong code is refused in the player's words: %s" % c.party.last_error)
	c.party.join_by_code("")
	check(String(c.party.last_error.get("code", "")) == "bad_code", "an empty code is refused without asking the lobby")
	c.party.close_link()
	c.process_mode = Node.PROCESS_MODE_DISABLED
	c.queue_free()
	await ticks(2)

	var hosted := [false]
	h.party.hosting_changed.connect(func(on: bool) -> void: hosted[0] = on)
	h.party.host_session("Coop test", true)
	await until(func() -> bool: return hosted[0], 10.0)
	check(hosted[0] and h.party.mode == DmNextParty.HOST and h.party.code.length() == 6 and bool(h.party.info.get("private", false)), "the host made a Closed party with a code (%s)" % h.party.code)
	check(h.party._relay != null and h.session.multiplayer.multiplayer_peer == h.party._relay, "the session now runs on the relay peer: the running world stayed")

	# the guest: joins by the code, the solo game is handed over to a guest game
	gq = new_branch()
	var g0 := await game(gq, "joiner")
	var got: Array = await seat(g0, func() -> void: g0.party.join_by_code(h.party.code))
	check(got.size() == 2 and g0.party.mode == DmNextParty.HANDOFF, "the guest joins by the code")
	if got.size() != 2:
		finish_early("the guest could not join")
		return
	var lob: DmLobbyClient = got[0]
	check(lob.in_session() and lob.peer_id == 2 and not lob.relay.is_empty(), "the lobby seated it as peer 2 and offered the test relay (%s)" % [lob.relay.get("port", 0)])
	g = await hand_over(g0, gq, "joiner", lob)
	gb_h = h.body_of(2)
	gb_g = g.local_body() if g.ready_ else null
	hb.hurt.connect(func(_a: float, src: Variant) -> void: _boss_hurt(1, src))
	gb_h.hurt.connect(func(_a: float, src: Variant) -> void: _boss_hurt(2, src))
	g.kill_credited.connect(func(_id: int, _d: String, _l: int, _e: bool, _a: String, _k: int, _x: float, _z: float) -> void: kills_guest += 1)
	g.core_host.enemy_died.connect(func(_id: int, _d: String, _l: int, _e: bool, _a: String, _s: int, _x: float, _z: float) -> void: died_guest += 1)


## The social flows, with the guest in: a friend's invite and an ask to join, answered by the host, seat a third player (who leaves again without playing).
func party_social() -> void:
	var cq := new_branch()
	var c := await game(cq, "third")
	# invite: the host invites the third player (a mutual friend); it accepts and is seated
	c.party.go_online()
	await until(func() -> bool: return c.party.link == "ready" and c.party.friends_online.has(101), 8.0)
	check(c.party.friends_online.has(101), "the third player sees its online friend (the lobby's presence)")
	h.party.invite_friend(103)
	await until(func() -> bool: return not c.party.invites.is_empty(), 8.0)
	check(c.party.invites.size() == 1 and int(c.party.invites[0]["from_id"]) == 101, "an invite from the host reaches the friend")
	var seated: Array = await seat(c, func() -> void: c.party.accept_invite(101))
	check(seated.size() == 2 and c.party.mode == DmNextParty.HANDOFF, "accepting the invite seats it (join_ready)")
	await until(func() -> bool: return h.session.multiplayer.get_peers().size() >= 1, 5.0)
	c.party.lobby.close()
	c.process_mode = Node.PROCESS_MODE_DISABLED
	c.queue_free()
	await ticks(30)

	# ask to join: a fresh solo third player asks, the host answers yes, the lobby lets it in
	var c2 := await game(cq, "third")
	c2.party.go_online()
	await until(func() -> bool: return c2.party.link == "ready" and c2.party.friends_online.has(101), 8.0)
	c2.party.ask_to_join(101)
	await until(func() -> bool: return not h.party.requests.is_empty(), 8.0)
	check(h.party.requests.size() == 1 and int(h.party.requests[0]["account_id"]) == 103, "the host receives the ask to join")
	var seated2 := [null]
	c2.party.join_ready.connect(func(l: DmLobbyClient, i: Dictionary) -> void: seated2[0] = [l, i])
	h.party.answer_request(103, true)
	await until(func() -> bool: return seated2[0] != null, 10.0)
	check(seated2[0] != null, "the answer lets the asker in: it joins by itself (join_ready)")
	c2.party.lobby.close()
	c2.process_mode = Node.PROCESS_MODE_DISABLED
	c2.queue_free()
	await ticks(30)
	check(h.session.get_roster().size() == 2 and h.net.guests() == [2], "the seats of the third player left the host's roster untouched (nobody said hello)")



func finish_early(why: String) -> void:
	printerr("coop: stopped early: " + why)
	check(false, why)
	stop_services()
	print("FAIL coop: %d of %d checks failed" % [fails, checks])
	quit(1)


# ------------------------------------------------------------------------------------------------------------------ the connection

func connection() -> void:
	check(g != null and g.ready_ and g.is_guest, "the guest's game is up")
	if g == null or not g.ready_:
		finish_early("the guest's game did not start")
		return
	check(g.core_host.puppet and not g.director.enabled and g.core_host.core.is_puppet() and not h.core_host.core.is_puppet(), "the guest's core is a puppet, the host's is not, the guest has no director")
	check(h.session.get_roster().size() == 2 and g.session.get_roster().size() == 2 and g.session.get_my_id() == 2, "both see a roster of two; the guest is peer 2")
	check(h.net.guests() == [2], "the host sends to the one guest")
	gb_h = h.body_of(2)
	gb_g = g.local_body()
	check(gb_h != null and gb_g != null and gb_h.core_id != 0 and hb.core_id != 0 and gb_h.core_id != hb.core_id, "the host registered both heroes as externals of its core (ids %d and %d)" % [hb.core_id, gb_h.core_id])
	await until(func() -> bool: return gb_g.core_id == gb_h.core_id and g.body_of(1).core_id == hb.core_id, 5.0)
	check(gb_g.core_id == gb_h.core_id and g.body_of(1).core_id == hb.core_id, "the guest's bodies carry the host's ids: its own hero %d, the host's %d" % [gb_g.core_id, g.body_of(1).core_id])
	check(g.core_host.hero_for(gb_g.core_id) == gb_g, "and the guest's core host maps the id to its own hero body")
	var udp := await until(func() -> bool: return h.party._relay.lane_to(2) == "udp" and g.party._relay.lane_to(1) == "udp", 8.0)
	check(udp, "both ends moved to the UDP lane (host to guest: %s, guest to host: %s)" % [h.party._relay.lane_to(2), g.party._relay.lane_to(1)])
	check(int(relay.stats["attached"]) >= 2, "the test relay holds both lanes (%s)" % str(relay.stats))
	await until(func() -> bool: return int(gb_h.character.get("level", 0)) == 14 and int(g.party.levels.get(2, 0)) == 14, 5.0)
	check(int(gb_h.character.get("level", 0)) == 14 and gb_h.discipline_id == "gravecaller", "the guest's profile reached the host: its hero is a level-14 Gravecaller there (%s)" % gb_h.character)
	check(int(g.party.levels.get(1, 0)) == 14 and int(g.party.levels.get(2, 0)) == 14, "and the guest knows the party's levels (%s)" % str(g.party.levels))
	for gm in [h, g]:
		var rows: Array = gm.ui_host.hud_state()["party"]
		var ok_rows := rows.size() == 2
		for r in rows:
			ok_rows = ok_rows and String(r["discipline"]).ends_with("Level 14")
		check(ok_rows, "%s's HUD lists both heroes with their levels (%s)" % ["the guest" if gm == g else "the host", str(rows.map(func(r: Dictionary) -> String: return "%s %s" % [r["name"], r["discipline"]]))])
	var st: Dictionary = g.core_host.core.replication_stats()
	check(int(st["baselines_applied"]) == 1 and st["need_baseline"] == false and g.net.stats["applied_baselines"] == 1, "the guest started from the host's baseline")
	check(h.core_host.core.replication_stats()["replicating"] == true, "the host collects events for a guest now")


# ------------------------------------------------------------------------------------------------------------------ comparing the guest's copy with the host's

func _boss_hurt(peer: int, src: Variant) -> void:
	var boss := h.bosses.active_boss()
	if boss != null and src is int and int(src) == boss.core_id and boss.core_id != 0:
		hurt_by_boss[peer] += 1


## One comparison, when the guest has just applied the last part of a frame the host sampled: the bodies the host had alive at that frame's last tick against the guest's copy.
## Positions: the guest's `net_pos` (where the snapshot put the body) must be the host's position within the wire's quantization, for every body both have. Sets: the live ids.
func compare_sample() -> void:
	var gcore: RefCounted = g.core_host.core
	var t := int(gcore.replication_stats()["last_tick"])
	if t == last_cmp_tick or not sampler.samples.has(t):
		return
	last_cmp_tick = t
	var smp: Dictionary = sampler.samples[t]
	for tk in range(t - int(smp["parts"]) + 1, t + 1):   # a part the network lost (unreliable: the next frame repairs it) leaves its bodies where the last frame put them
		if not g.net.has_applied(tk):
			cmp["lossy"] += 1
			return
	var pos: Dictionary = smp["pos"]
	var ids: PackedInt32Array = gcore.enemy_ids()
	var st: PackedInt32Array = gcore.enemy_states()
	var live := {}
	for i in ids.size():
		if st[i] != 6:
			live[ids[i]] = true
	var tids: PackedInt32Array = gcore.thrall_ids()
	var tst: PackedInt32Array = gcore.thrall_states()
	var tlive := {}
	for i in tids.size():
		if tst[i] != 4:
			tlive[tids[i]] = true
	var set_ok: bool = (smp["enemies"] as Array).size() == live.size() and (smp["thralls"] as Array).size() == tlive.size()
	for id in smp["enemies"]:
		if not live.has(id):
			set_ok = false
		else:
			var info: Dictionary = gcore.enemy_info(id)
			cmp["bodies"] += 1
			if info.is_empty() or (info["net_pos"] as Vector2).distance_to(pos[id]) > POS_QUANTUM_BOUND:
				cmp["bad"] += 1

	for id in smp["thralls"]:
		if not tlive.has(id):
			set_ok = false
		else:
			var tinfo: Dictionary = gcore.thrall_info(id)
			cmp["bodies"] += 1
			if tinfo.is_empty() or (tinfo["net_pos"] as Vector2).distance_to(pos[id]) > POS_QUANTUM_BOUND:
				cmp["bad"] += 1
	cmp["frames"] += 1
	cmp["multi"] += 1 if int(smp["parts"]) > 1 else 0
	if not set_ok:
		cmp["set_bad"] += 1


func reset_cmp() -> void:
	cmp = {"frames": 0, "bodies": 0, "bad": 0, "set_bad": 0, "multi": 0, "lossy": 0}


## Runs `n` ticks, comparing at each frame and calling `each` every tick.
func watch(n: int, each: Callable = Callable()) -> void:
	for i in n:
		await physics_frame
		compare_sample()
		if each.is_valid():
			each.call(i)


## Keeps at least `n` foes within 11 m of a hero (host side): spawns a few at 6 to 9 m when fewer stand there.
func foes_near(body: DmHeroBody, n: int) -> void:
	if h.core_host.enemies_in_radius(body.position, 11.0).size() >= n:
		return
	for k in n:
		var a := rng.randf() * TAU
		var p := h.world.nav_clamp(body.position + Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(6.0, 9.0))
		h.core_host.spawn_enemy("robber" if k % 2 == 0 else "hound", p, 1, 1.0, 1.0, false, "graves", false)


func nearest_enemy(from: Vector3, within: float, game_: DmNextGame) -> int:
	var best := 0
	var bd := within
	for id in game_.core_host.enemies_in_radius(from, within):
		var p := game_.core_host.enemy_position(id)
		var d := Vector2(p.x - from.x, p.z - from.z).length()
		if d < bd:
			bd = d
			best = id
	return best


# ------------------------------------------------------------------------------------------------------------------ the waves, in a still moment

func waves_still() -> void:
	h.director.enabled = false
	var kinds := ["robber", "hound", "penitent", "sac", "moth", "bat", "ghoul"]
	var made := 0
	var tries := 0
	while made < 40 and tries < 400:
		tries += 1
		var a := rng.randf() * TAU
		var r := rng.randf_range(24.0, 40.0)
		var p := h.world.nav_clamp(hb.position + Vector3(cos(a), 0.0, sin(a)) * r)
		if Vector2(p.x - hb.position.x, p.z - hb.position.z).length() < 19.0:
			continue   # beyond the aggro range of 15 m, so the bodies only wander
		h.core_host.spawn_enemy(kinds[made % kinds.size()], p, 1, 1.0, 1.0, false, "graves", false)
		made += 1
	check(made == 40, "40 idle bodies stand far from both heroes (%d made)" % made)
	await ticks(240)
	reset_cmp()
	await watch(300)
	var gcore: RefCounted = g.core_host.core
	var hcore: RefCounted = h.core_host.core
	check(cmp["frames"] >= 20, "a still moment: the guest was compared at %d snapshots" % cmp["frames"])
	check(cmp["set_bad"] == 0, "in every one the guest's live bodies were exactly the host's (%d differed)" % cmp["set_bad"])
	check(cmp["bodies"] >= 40 * 20 and cmp["bad"] == 0, "and every position (%d compared) was the host's at that tick within the 1 cm quantization (%d off)" % [cmp["bodies"], cmp["bad"]])
	check(hcore.enemy_count() == 40 and gcore.enemy_count() == 40, "both cores hold the same 40 bodies")
	var drawn_h: int = int(h.core_host.view.stats()["bodies"])
	var drawn_g: int = int(g.core_host.view.stats()["bodies"])
	check(drawn_h == 40 and drawn_g == 40, "and both crowds draw them (%d and %d bodies)" % [drawn_h, drawn_g])
	var moved := 0
	for id in hcore.enemy_ids():
		var gp: Vector2 = gcore.enemy_info(id)["pos"]
		var hp2: Vector2 = hcore.enemy_info(id)["pos"]
		moved += 1 if gp.distance_to(hp2) < 1.0 else 0
	check(moved >= 38, "the guest's eased positions are close to the host's (%d of 40 within 1 m)" % moved)
	var st: Dictionary = gcore.replication_stats()
	check(st["desync"] == 0 and st["batches_refused"] == 0 and st["snapshots_refused"] == 0, "no desync, nothing refused (%d snapshots, %d batches applied)" % [st["snapshots_applied"], st["batches_applied"]])
	for id in hcore.enemy_ids():
		h.core_host.remove_enemy(id)
	await ticks(30)
	check(h.core_host.core.enemy_count() == 0 and g.core_host.core.enemy_count() == 0, "removing them removes them on the guest too")


# ------------------------------------------------------------------------------------------------------------------ casts and thralls

func casts_and_thralls() -> void:
	await until(func() -> bool: return gb_h.get_node_or_null("Rites") != null and gb_g.get_node_or_null("Rites") != null, 5.0)
	var rites_h_for_g := gb_h.get_node("Rites") as DmRiteCaster   # where the guest's casts resolve: the host's copy of its caster
	var rites_g := gb_g.get_node("Rites") as DmRiteCaster          # the guest's own: a request and the picture
	var rites_h := hb.get_node("Rites") as DmRiteCaster
	check(rites_h_for_g != null and rites_g != null and rites_g.is_owner_peer() and not rites_g._is_host(), "the guest owns its caster, the host resolves it")
	var hits := {"n": 0, "ids": [], "killed": 0}
	rites_h_for_g.hit_resolved.connect(func(_r: String, id: int, _a: float, _c: bool, killed: bool) -> void:
		hits["n"] += 1
		hits["ids"].append(id)
		hits["killed"] += 1 if killed else 0)
	var nums := {"host": 0, "guest": 0}
	rites_h_for_g.hit_number.connect(func(_p: Vector3, _a: float, _c: bool) -> void: nums["host"] += 1)
	rites_g.hit_number.connect(func(_p: Vector3, _a: float, _c: bool) -> void: nums["guest"] += 1)
	var seen_damaged := {}
	g.core_host.enemy_damaged.connect(func(id: int, _s: int, _a: float, _hp: float) -> void: seen_damaged[id] = true)
	var events := {"host": 0, "guest": 0}
	rites_h_for_g.event_played.connect(func(_e: Dictionary) -> void: events["host"] += 1)
	rites_g.event_played.connect(func(_e: Dictionary) -> void: events["guest"] += 1)
	# the guest's thralls are the host's bodies: count them from the core, and the swings the guest's puppet sees
	var swings := {"host": 0, "guest": 0}
	h.core_host.thrall_swing.connect(func(_id: int, _sw: int, _t: int, _ax: float, _az: float, _d: float) -> void: swings["host"] += 1)
	g.core_host.thrall_swing.connect(func(_id: int, _sw: int, _t: int, _ax: float, _az: float, _d: float) -> void: swings["guest"] += 1)

	# the waves: the host's director fills the Graves; the guest's puppet follows
	h.director.enabled = true
	h.director.wave_size = 9
	check(await until(func() -> bool: return h.core_host.alive_count() >= 6, 20.0), "the host's director spawned a wave")
	check(await until(func() -> bool: return g.core_host.core.enemy_count() >= 6, 5.0), "and the guest's puppet shows it (%d bodies there, %d on the host)" % [g.core_host.core.enemy_count(), h.core_host.core.enemy_count()])
	reset_cmp()
	sturdy(hb)
	sturdy(gb_h)
	# the heroes meet foes: some always stand near the guest's hero (a wave may wander off); the target is found on the GUEST's puppet and cast at
	var target := [0]
	var cast_t := [0]
	await watch(1200, func(i: int) -> void:
		if i % 60 == 0:
			hb.restore_vitals()
			gb_h.restore_vitals()
		if i % 30 == 0:
			foes_near(gb_h, 4)
		if hits["n"] >= 4 or i % 20 != 0:
			return
		target[0] = nearest_enemy(gb_g.position, 11.0, g)
		if target[0] != 0:
			cast_t[0] += 1
			rites_g.request_cast("bone_needle", g.core_host.enemy_position(target[0]), target[0]))
	check(cast_t[0] > 0, "the guest found targets near its hero on its puppet and cast at them (%d requests)" % cast_t[0])
	check(hits["n"] >= 1, "the HOST resolved the guest's cast on its core: %d hits on %d bodies, %d kills" % [hits["n"], hits["ids"].size(), hits["killed"]])
	check(rites_h_for_g.rejected_intents == 0, "no cast of the guest was taken for a forged intent")
	check(nums["host"] > 0 and nums["guest"] > 0, "the damage shows on both: numbers for the guest's hits on the host (%d) and on the guest (%d)" % [nums["host"], nums["guest"]])
	check(events["host"] > 0 and events["guest"] > 0, "and the cast's visual events played on both (%d and %d)" % [events["host"], events["guest"]])
	var shown := 0
	for id in hits["ids"]:
		shown += 1 if seen_damaged.has(id) else 0
	check(shown >= 1, "the guest's puppet saw the damage on %d of the bodies the guest hit (derived from their health)" % shown)
	check(cmp["frames"] >= 100 and cmp["bad"] == 0, "in the fight every position the guest holds is the host's at that tick within the quantization (%d bodies in %d snapshots, %d off)" % [cmp["bodies"], cmp["frames"], cmp["bad"]])

	# Exhume: a corpse near the guest's hero, raised by the guest's request
	foes_near(gb_h, 4)
	await ticks(30)
	var victim := nearest_enemy(gb_h.position, 12.0, h)
	check(victim != 0, "an enemy stands within reach of the guest's hero")
	var vpos := h.core_host.enemy_position(victim)
	h.core_host.damage(victim, 1.0e7, gb_h.core_id)
	check(await until(func() -> bool: return g.core_host.core.corpse_count() > 0 and h.core_host.core.corpse_count() > 0, 3.0), "the kill left a corpse on both sides")
	var cpos: PackedFloat32Array = g.core_host.core.corpse_positions()
	var before_host := h.core_host.thrall_count(gb_h.core_id)
	rites_g.request_cast("exhume", Vector3(cpos[0], 0.0, cpos[1]), -1)
	check(await until(func() -> bool: return h.core_host.thrall_count(gb_h.core_id) > before_host, 3.0), "the guest's Exhume raised a thrall on the host, owned by the guest's hero external (core id %d)" % gb_h.core_id)
	check(await until(func() -> bool: return g.core_host.thrall_count(gb_g.core_id) >= 1, 3.0), "the guest's puppet shows it under the same owner id")
	var tid := 0
	var owners: PackedInt32Array = h.core_host.core.thrall_owners()
	var tids: PackedInt32Array = h.core_host.core.thrall_ids()
	for i in tids.size():
		if owners[i] == gb_h.core_id:
			tid = tids[i]
	var t0: Vector2 = h.core_host.core.thrall_info(tid)["pos"]
	var base_swings: int = swings["host"]
	for k in 4:   # foes for it: three robbers close to the thrall (it walks to its target and swings)
		var a2 := float(k) * 1.7
		h.core_host.spawn_enemy("robber", h.world.nav_clamp(Vector3(t0.x + cos(a2) * 5.0, 0.0, t0.y + sin(a2) * 5.0)), 1, 1.0, 1.0, false, "graves", false)
	await watch(420)
	await until(func() -> bool: return swings["host"] > base_swings and swings["guest"] > 0, 8.0)
	var t1: Vector2 = h.core_host.core.thrall_info(tid)["pos"] if not h.core_host.core.thrall_info(tid).is_empty() else t0
	var alive_t: bool = not h.core_host.core.thrall_info(tid).is_empty() and int(h.core_host.core.thrall_info(tid)["state"]) != 4
	check(tid != 0 and (t0.distance_to(t1) > 0.3 or swings["host"] > base_swings), "the host simulates the thrall: it moved %.1f m / swung %d times" % [t0.distance_to(t1), swings["host"] - base_swings])
	if alive_t:
		var gt: Dictionary = g.core_host.core.thrall_info(tid)
		check(not gt.is_empty() and (gt["pos"] as Vector2).distance_to(t1) < 1.5, "and the guest's copy of it is where the host's is (within 1.5 m of the host's, easing)")
	check(swings["guest"] > 0 and swings["host"] > 0, "the guest's puppet saw the legion swing (%d swings there, %d on the host)" % [swings["guest"], swings["host"]])
	var live_h: int = int(h.core_host.view.stats()["live"])
	var live_g: int = int(g.core_host.view.stats()["live"])
	check(live_g >= 1 and absi(live_h - live_g) <= 6, "both crowds draw about the same live bodies (host %d, guest %d)" % [live_h, live_g])
	# let the world settle, then the sets are equal again
	h.director.enabled = false
	for id in h.core_host.core.enemy_ids():
		h.core_host.remove_enemy(id)
	await until(func() -> bool: return h.core_host.core.enemy_count() == g.core_host.core.enemy_count() and h.core_host.core.enemy_count() <= 1, 6.0)   # the dying leave 4 s after their death
	check(h.core_host.core.enemy_count() == g.core_host.core.enemy_count(), "with no waves, the guest holds as many bodies as the host (%d)" % h.core_host.core.enemy_count())


# ------------------------------------------------------------------------------------------------------------------ the Gravedigger King fights both

## Makes a hero too sturdy to die in a fight (a test of the crowd or of the King, not of the heroes' health: the guest's death has its own test).
func sturdy(b: DmHeroBody) -> void:
	b.p["stats"]["maxHp"] = 1.0e7
	b.p["hp"] = 1.0e7
	b._mirror_from_state()


func the_king() -> void:
	h.director.enabled = false
	for id in h.core_host.core.enemy_ids():
		h.core_host.remove_enemy(id)
	await ticks(30)
	var site := h.bosses.site_pos("gravedigger")
	check(site != Vector3.INF, "the King's grave is in the Graves")
	await until(func() -> bool: return hb.alive and gb_h.alive, 8.0)
	hb.teleport(site + Vector3(2.0, 0.0, 0.0))
	gb_h.teleport(site + Vector3(-2.0, 0.0, 0.0))
	sturdy(hb)
	sturdy(gb_h)
	await until(func() -> bool: return gb_g.position.distance_to(site) < 4.5, 3.0)
	var woke := [""]
	h.bosses.summoned.connect(func(id: String, by: int) -> void: woke[0] = "%s/%d" % [id, by])
	var cost := int(DmContent.boss("gravedigger")["shards"])
	g.bosses.request_summon("gravedigger")
	await ticks(10)
	check(woke[0] == "" and h.bosses.active_boss() == null, "a guest without the King's soul shards is refused on its own client (it pays with its own)")
	g.joiner.prog.add_shards(cost)
	g.bosses.request_summon("gravedigger")
	check(await until(func() -> bool: return woke[0] != "", 4.0) and woke[0] == "gravedigger/2", "the guest's request woke the King on the host (%s)" % woke[0])
	check(await until(func() -> bool: return int(g.joiner.prog.local["shards"]) == 0, 2.0), "the guest's own shards paid for it")
	check(await until(func() -> bool: return h.bosses.active_boss() != null and h.bosses.active_boss().is_hittable(), 12.0), "the King is awake and can be hurt")
	var bh := h.bosses.active_boss()
	check(await until(func() -> bool: return g.bosses.active_boss() != null, 5.0), "the guest has his body too, awake")
	var bg := g.bosses.active_boss()
	var rites_h := hb.get_node("Rites") as DmRiteCaster
	var rites_g := gb_g.get_node("Rites") as DmRiteCaster
	var rites_h_for_g := gb_h.get_node("Rites") as DmRiteCaster
	var king_hits := {"host": 0, "guest": 0}
	var rej := {}
	rites_h.cast_rejected.connect(func(r: String, why: String) -> void: rej["h:" + r + ":" + why] = int(rej.get("h:" + r + ":" + why, 0)) + 1)
	rites_g.cast_rejected.connect(func(r: String, why: String) -> void: rej["g:" + r + ":" + why] = int(rej.get("g:" + r + ":" + why, 0)) + 1)
	rites_h.hit_resolved.connect(func(_r: String, id: int, _a: float, _c: bool, _k: bool) -> void: king_hits["host"] += 1 if id == bh.core_id else 0)
	rites_h_for_g.hit_resolved.connect(func(_r: String, id: int, _a: float, _c: bool, _k: bool) -> void: king_hits["guest"] += 1 if id == bh.core_id else 0)
	var tele := [0]
	var phases := {}
	for i in 2400:
		await physics_frame
		compare_sample()
		if i % 30 == 0:
			rites_h.request_cast("bone_needle", bh.global_position, -1)
			rites_g.request_cast("bone_needle", bh.global_position, -1)
		if not bg.telegraphs.is_empty():
			tele[0] += 1
		phases[bg.phase] = true
		if i > 600 and king_hits["host"] > 3 and king_hits["guest"] > 3 and hurt_by_boss[1] > 0 and hurt_by_boss[2] > 0 and tele[0] > 0:
			break
	if not rej.is_empty():
		print("INFO coop the King's fight: casts the rules refused: %s" % str(rej))
	check(king_hits["host"] > 0 and king_hits["guest"] > 0, "the casts of both heroes hurt him: the host's hero %d hits, the guest's %d (resolved on the host)" % [king_hits["host"], king_hits["guest"]])
	check(hurt_by_boss[1] > 0 and hurt_by_boss[2] > 0, "and he hurt both heroes: %d blows on the host's hero, %d on the guest's" % [hurt_by_boss[1], hurt_by_boss[2]])
	check(bh.hp < bh.max_hp, "his health fell: %.0f of %.0f" % [bh.hp, bh.max_hp])
	check(absf(bg.hp - bh.hp) <= bh.max_hp * 0.03 and bg.phase == bh.phase, "the guest's copy follows his state: %.0f against %.0f hp, phase %d against %d" % [bg.hp, bh.hp, bg.phase, bh.phase])
	check(tele[0] > 0, "the guest's copy showed his telegraphs (%d snapshots)" % tele[0])
	check(g.bosses.states_applied > 0 and h.bosses.packets_sent > 0, "his state travelled as today's code sends it (%d states applied there)" % g.bosses.states_applied)
	# the end of the fight: he falls to a blow of the host's hero, and the guest sees him fall
	var fell := [false]
	h.bosses.defeated.connect(func(_id: String, _k: int, _p: Vector3) -> void: fell[0] = true)
	bh.take_damage(1.0e9, hb)
	check(await until(func() -> bool: return fell[0] and bh.dead, 3.0), "the King fell on the host")
	check(await until(func() -> bool: return bg.bstate.state == "dead" and bg.hp <= 0.0, 3.0), "and on the guest")


# ------------------------------------------------------------------------------------------------------------------ the guest dies and gets up

func guest_death() -> void:
	var died := [0]
	var up := [0]
	gb_h.died.connect(func(_b: DmHeroBody) -> void: died[0] += 1)
	h.hero_respawned.connect(func(b: DmHeroBody) -> void: up[0] += 1 if b == gb_h else 0)
	gb_h.p["stats"]["maxHp"] = 400.0   # back from the King's sturdiness to a real health pool
	gb_h.p["hp"] = 400.0
	gb_h._mirror_from_state()
	await ticks(40)
	check(gb_g.alive and not bool(g.ui_host.hud_state()["death"]["show"]), "the guest's hero is alive and its HUD shows no veil")
	gb_h.take_damage(1.0e9, 0)
	check(died[0] == 1 and not gb_h.alive, "the host killed the guest's hero")
	check(await until(func() -> bool: return not gb_g.alive, 2.0) and gb_g.hp <= 0.0, "the guest's body died on the guest: the vitals arrived")
	await ticks(30)
	check(bool(g.ui_host.hud_state()["death"]["show"]), "the guest's HUD shows the death veil")
	check(await until(func() -> bool: return up[0] == 1 and gb_g.alive, 8.0), "the hero got up on both sides after the respawn time")
	await ticks(30)
	check(not bool(g.ui_host.hud_state()["death"]["show"]) and gb_g.hp > 0.0, "and the veil is gone")


# ------------------------------------------------------------------------------------------------------------------ the guest's own account

func guest_account() -> void:
	var gcid := int(accounts["joiner"]["ch"]["id"])
	var gm: DmRewardsMember = h.rewards.members.get(gcid)
	check(gm != null and gm.remote and gm.rolls_own_drops and gm.peer_id == gb_h.owner_peer, "the host made the guest a rewards member: its character, remote, rolling its own drops")
	check(await until(func() -> bool: return g.joiner != null and g.joiner.backend_ok and gm.blocked == "" and gm.joined, 5.0),
		"the guest joined the host's backend party session with its own account")
	check(await until(func() -> bool: return h.remote_builds.has(gb_h.owner_peer), 5.0), "the host read the guest's build from the server (B22)")
	check(g.world.unlocked.keys() == h.world.unlocked.keys() and not h.party._seals.is_empty(), "the guest's doors follow the host's seals (%s)" % str(g.world.unlocked.keys()))
	check(g.rewards == null and g.my_member() == g.joiner.member and g.loot != null and g.ui_host.prog == g.joiner.prog and g.belt() == g.loot.guest_belt,
		"the guest's member, bag, belt and HUD are its own account's")
	var xp0: int = int(g.joiner.member.stats["xp_applied"])
	var drops0: int = g.joiner.drops_received
	gb_h.teleport(hb.position + Vector3(3.0, 0.0, 0.0))   # side by side (the guest got up at the door)
	await ticks(10)
	var hpos := hb.position
	var gpos := gb_h.position
	var mid := (hpos + gpos) * 0.5
	check(Vector2(hpos.x - gpos.x, hpos.z - gpos.z).length() < 30.0, "the two heroes stand together (%.1f m apart)" % Vector2(hpos.x - gpos.x, hpos.z - gpos.z).length())
	for i in 3:
		var id := h.core_host.spawn_enemy("robber", mid + Vector3(float(i), 0.0, 1.0), 1, 1.0, 0.0, true, "graves", false)
		h.core_host.damage(id, 1.0e6, hb.core_id)
	await ticks(3)
	check(int(gm.stats["kills_earned"]) >= 3, "the guest's member earned the host's kills near it (%d)" % int(gm.stats["kills_earned"]))
	check(await until(func() -> bool: return g.joiner.drops_received > drops0, 4.0), "the guest's drops reached it (%d)" % (g.joiner.drops_received - drops0))
	await h.rewards.flush()
	check(await until(func() -> bool: return int(g.joiner.member.stats["xp_applied"]) > xp0, 4.0) and int(g.joiner.member.stats["kills_accepted"]) >= 3,
		"the host's accepted report paid the guest's XP and kills on its own account (%d XP)" % (int(g.joiner.member.stats["xp_applied"]) - xp0))
	var sv: DmResult = await h.api.session_get(h.rewards.session_id)
	var counted := 0
	if sv.ok:
		for e in sv.data["members"]:
			if int(e["characterId"]) == gcid:
				counted = int(e["acceptedKills"])
	check(counted >= 3, "the server counted the guest's kills for its character (%d)" % counted)


# ------------------------------------------------------------------------------------------------------------------ chat and the ground

func chat_and_ground() -> void:
	h.ui_host.send_chat("over here")
	check(await until(func() -> bool: return g.party.chat_log.any(func(l: String) -> bool: return l == "[hostess] over here"), 3.0) and h.party.chat_log.has("[hostess] over here"),
		"the host's chat line reaches both, with its name (%s)" % str(g.party.chat_log))
	g.ui_host.send_chat("coming")
	check(await until(func() -> bool: return h.party.chat_log.has("[joiner] coming") and g.party.chat_log.has("[joiner] coming"), 3.0), "the guest's chat line goes through the host to both (%s / %s)" % [str(h.party.chat_log), str(g.party.chat_log)])
	# a piece the guest found while the host was there (the server's record), dropped from its Reliquary
	var gcid := int(accounts["joiner"]["ch"]["id"])
	var acc: Dictionary = {}
	for a: Dictionary in mock.db["accounts"].values():
		if a.get("character") is Dictionary and int(a["character"]["id"]) == gcid:
			acc = a
	var iid := mock._mint_instance(acc, "staff_oak", 3, [])
	var sid: String = h.rewards.session_id
	mock._instances(acc)[str(iid)]["found_session"] = sid
	mock._instances(acc)[str(iid)]["found_at"] = mock._now()
	var free := mock._free_bag_slot(acc)
	acc["slots"].append({"slot_index": free, "item_id": "staff_oak", "quantity": 1, "equipped": 0, "instance_id": iid})
	await g.loot.refresh_inventory()
	var row: Dictionary = {}
	for r: Dictionary in g.loot.slots():
		if int(r.get("slot_index", -1)) == free:
			row = r
	var oaks0 := _count(h, "staff_oak")
	var err: String = await g.ui_host.drop_gear(row)
	check(err == "" and not g.loot.slots().any(func(r: Dictionary) -> bool: return int(r.get("slot_index", -1)) == free), "the guest dropped the piece from its bag (%s)" % err)
	var hm := h.my_member()
	var shared := func() -> Dictionary:
		for d: Dictionary in hm.loot_view._drops:
			if d.has("drop_id"):
				return d
		return {}
	check(await until(func() -> bool: return not shared.call().is_empty(), 3.0), "the dropped piece lies on the host's ground (the server lets the host take it)")
	var d: Dictionary = shared.call()
	if d.is_empty():
		return
	await h.loot._on_claim(d)
	check(_count(h, "staff_oak") == oaks0 + 1, "the host picked it up into its own bag")
	check(await until(func() -> bool: return not g.my_member().loot_view._drops.any(func(x: Dictionary) -> bool: return x.get("drop_id") == d["drop_id"]), 3.0), "and the guest's copy is gone")


func _count(gm: DmNextGame, item_id: String) -> int:
	var n := 0
	for r: Dictionary in gm.loot.slots():
		if String(r.get("item_id", "")) == item_id:
			n += int(r.get("quantity", 1))
	return n


# ------------------------------------------------------------------------------------------------------------------ versions

func versions() -> void:
	var roster_before := h.session.get_roster().size()
	var host_wire := h.session.wire
	var host_build := "20261016.100000-aaaaaaa"
	var cases := [
		["a guest whose core speaks a NEWER wire version", {"wire": host_wire + 1}, DmSession.wire_text(host_wire, host_wire + 1), "dev"],
		["a guest whose core speaks an OLDER wire version", {"wire": maxi(0, host_wire - 1)}, DmSession.wire_text(host_wire, maxi(0, host_wire - 1)), "dev"],
		["a guest on an OLDER release build", {"build": "20261016.090000-bbbbbbb"}, DmSession.version_text(host_build, "20261016.090000-bbbbbbb"), host_build],
		["a guest on a NEWER release build", {"build": "20261016.110000-ccccccc"}, DmSession.version_text(host_build, "20261016.110000-ccccccc"), host_build],
	]
	for c in cases:
		h.session.build_version = String(c[3])
		var br := new_branch()
		var v := await game(br, "third")
		var got: Array = await seat(v, func() -> void: v.party.join_by_code(h.party.code))
		check(got.size() == 2, "%s is seated by the lobby" % c[0])
		if got.size() != 2:
			continue
		last_refusal = ""
		var vg := await hand_over(v, br, "third", got[0], c[1])
		check(last_refusal == String(c[2]) and last_refusal != "", "%s is refused in the player's words: \"%s\"" % [c[0], last_refusal])
		check(not vg.ready_, "and its game did not start")
		(got[0] as DmLobbyClient).close()
		vg.process_mode = Node.PROCESS_MODE_DISABLED
		vg.queue_free()
		await ticks(40)
		check(h.session.get_roster().size() == roster_before and h.net.guests() == [2], "the party is untouched (roster %d, guests %s)" % [h.session.get_roster().size(), h.net.guests()])
	h.session.build_version = DmBuild.version()
	# the same words say which side is behind
	check(DmSession.wire_text(1, 0).contains("newer version") and DmSession.wire_text(1, 2).contains("older version"), "the words name the side that must update")


# ------------------------------------------------------------------------------------------------------------------ the Full Party

func full_party() -> void:
	h.director.enabled = false
	await until(func() -> bool: return h.bosses.bosses.is_empty(), 12.0)
	for id in h.core_host.core.enemy_ids():
		h.core_host.remove_enemy(id)
	var centre := h.world.spawn_point()
	hb.teleport(centre + Vector3(-3.0, 0.0, 0.0))
	gb_h.teleport(centre + Vector3(3.0, 0.0, 0.0))
	sturdy(hb)
	sturdy(gb_h)
	await ticks(20)
	var core: RefCounted = h.core_host.core
	var gcore: RefCounted = g.core_host.core
	var kinds := ["warrior", "warrior", "warrior", "shieldbearer", "hound", "archer", "warrior", "shieldbearer"]
	var wave := ["robber", "hound", "robber", "penitent", "bat", "ghoul", "robber", "moth", "hound", "sac", "bat", "ghoul"]
	var owners := [hb.core_id, gb_h.core_id]
	var refill := func(tick: int) -> void:
		if tick % 6 != 0:
			return
		var live: int = h.core_host.alive_count()
		for i in maxi(0, 72 - live):
			var a := rng.randf() * TAU
			var r := rng.randf_range(9.0, 24.0)
			h.core_host.spawn_enemy(wave[rng.randi() % wave.size()], h.world.nav_clamp(centre + Vector3(cos(a), 0.0, sin(a)) * r), 1, 1.0, 1.0, tick % 12 == 0 and i == 0, "graves", false)
		for k in 2:
			for j in maxi(0, 16 - h.core_host.thrall_count(owners[k])):
				var p := (hb if k == 0 else gb_h).position
				core.raise_thrall(thrall_stats(kinds[rng.randi() % kinds.size()], 900.0, 14.0), owners[k], Vector2(p.x, p.z + 2.0), 0.0, 20.0)
	await watch(240, refill)   # the ramp: bodies spawn, the legions stand, the first batches and baselines settle
	check(h.core_host.alive_count() >= 60 and h.core_host.thrall_count(owners[0]) + h.core_host.thrall_count(owners[1]) >= 28, "the Full Party stands: %d enemies, %d thralls" % [h.core_host.alive_count(), h.core_host.thrall_count(owners[0]) + h.core_host.thrall_count(owners[1])])
	var kb0 := h.net.stats.duplicate()
	relay.max_in = 0
	relay.max_out = 0
	var m0 := relay.mark()
	reset_cmp()
	var spread := {"max": 0, "sum": 0, "n": 0}
	var n := 1200
	await watch(n, func(i: int) -> void:
		refill.call(i)
		if i % 20 == 0:
			var d := absi(h.core_host.alive_count() - g.core_host.alive_count())
			spread["max"] = maxi(int(spread["max"]), d)
			spread["sum"] += d
			spread["n"] += 1)
	var m1 := relay.mark()
	var secs := float(n) / 60.0
	var hin := _diff(m0, m1, 1, "in")
	var gout := _diff(m0, m1, 2, "out")
	var hnet := h.net.stats
	var frames: int = int(hnet["frames"]) - int(kb0["frames"])
	var parts: int = int(hnet["parts"]) - int(kb0["parts"])
	var snap_b: int = int(hnet["snapshot_bytes"]) - int(kb0["snapshot_bytes"])
	var rel_b: int = int(hnet["reliable_bytes"]) - int(kb0["reliable_bytes"])
	print("INFO coop Full Party (%d enemies, %d thralls, %.0f s, one guest): host to relay %.1f KB/s in %.0f packets/s (limits: 1,024 KB/s, 600 packets/s: %.1f%% and %.1f%%); relay to guest %.1f KB/s in %.0f packets/s" % [
		h.core_host.alive_count(), h.core_host.thrall_count(owners[0]) + h.core_host.thrall_count(owners[1]), secs, hin[1] / secs / 1024.0, hin[0] / secs,
		hin[1] / secs / RELAY_BYTES_PER_S * 100.0, hin[0] / secs / RELAY_PACKETS_PER_S * 100.0, gout[1] / secs / 1024.0, gout[0] / secs])
	print("INFO coop Full Party snapshots: %d frames, %d packets (%.2f a frame), %.1f KB/s of snapshots + %.1f KB/s of reliable batches to the guest; largest part %d B (limit %d), largest relay packet %d B = a game packet of %d B (limit %d)" % [
		frames, parts, float(parts) / maxf(frames, 1), snap_b / secs / 1024.0, rel_b / secs / 1024.0, int(hnet["max_part"]), DmNextNet.PART_MAX, relay.max_in, relay.max_in - DmUdpRelay.HEADER, PACKET_LIMIT])
	check(frames >= 1100 / 3 and parts >= frames, "the host sent snapshots at 20 Hz (%d frames in %.0f s)" % [frames, secs])
	check(int(hnet["max_part"]) <= DmNextNet.PART_MAX and relay.max_in - DmUdpRelay.HEADER <= PACKET_LIMIT and relay.max_out - DmUdpRelay.HEADER <= PACKET_LIMIT, "no game packet is over %d bytes: the largest was %d B (a snapshot part of at most %d B)" % [PACKET_LIMIT, maxi(relay.max_in, relay.max_out) - DmUdpRelay.HEADER, int(hnet["max_part"])])
	check(relay.max_in <= ENET_FREE and relay.max_out <= ENET_FREE, "and the relay's packets (with their 6-byte header) stay under the %d bytes ENet sends in one datagram: %d B" % [ENET_FREE, maxi(relay.max_in, relay.max_out)])
	check(hin[0] / secs < RELAY_PACKETS_PER_S and hin[1] / secs < RELAY_BYTES_PER_S and gout[0] / secs < RELAY_PACKETS_PER_S, "the host's connection stays inside the relay's limits")
	check(cmp["frames"] >= 300 and cmp["bad"] == 0, "in the Full Party's fight the guest's positions are the host's at that tick within the quantization (%d bodies in %d snapshots, %d off)" % [cmp["bodies"], cmp["frames"], cmp["bad"]])
	check(int(spread["max"]) <= 14 and float(spread["sum"]) / maxf(spread["n"], 1) <= 5.0, "the counts follow: the guest's live bodies differ from the host's by %.1f on average, %d at most" % [float(spread["sum"]) / maxf(spread["n"], 1), spread["max"]])
	var gst: Dictionary = gcore.replication_stats()
	check(gst["desync"] == 0 and gst["batches_refused"] == 0 and gst["snapshots_refused"] == 0 and int(g.net.stats["asked"]) == 0, "no desync, no refused message, no baseline asked for (%d batches, %d snapshots applied)" % [gst["batches_applied"], gst["snapshots_applied"]])
	# the same fight with the cut lowered to 500 bytes: many parts a frame, and the guest still holds the host's positions
	h.net.part_max = 500
	reset_cmp()
	await watch(420, refill)
	h.net.part_max = DmNextNet.PART_MAX
	var g2: Dictionary = gcore.replication_stats()
	print("INFO coop guest snapshots: %d applied, %d stale, %d records for bodies not met yet, %d for the dead" % [g2["snapshots_applied"], g2["snapshots_stale"], g2["records_unknown"], g2["records_dead"]])
	check(cmp["multi"] >= 50 and cmp["frames"] >= 100 and cmp["bad"] == 0, "cut into packets of at most 500 B (several a frame: %d of %d frames) the guest still holds the host's positions (%d bodies, %d off)" % [cmp["multi"], cmp["frames"], cmp["bodies"], cmp["bad"]])


func _diff(a: Dictionary, b: Dictionary, pid: int, dir: String) -> Array:
	var x: Dictionary = a.get(pid, {"in_packets": 0, "in_bytes": 0, "out_packets": 0, "out_bytes": 0})
	var y: Dictionary = b.get(pid, {"in_packets": 0, "in_bytes": 0, "out_packets": 0, "out_bytes": 0})
	return [float(y[dir + "_packets"]) - float(x[dir + "_packets"]), float(y[dir + "_bytes"]) - float(x[dir + "_bytes"])]


# ------------------------------------------------------------------------------------------------------------------ the guest leaves

func leaving() -> void:
	h.director.enabled = false
	for id in h.core_host.core.enemy_ids():
		h.core_host.remove_enemy(id)
	await ticks(120)
	print("INFO coop kills: the host credited %s (%d), its core saw %d deaths; the guest's puppet saw %d deaths and credited %d" % [str(kills_host), kills_host.values().reduce(func(a: int, b: int) -> int: return a + b, 0), died_host, died_guest, kills_guest])
	var total := 0
	var twice := 0
	for k in kills_host:
		total += int(kills_host[k])
	for id in credited:
		twice += 1 if int(credited[id]) > 1 else 0
	check(kills_guest == 0 and died_guest > 0, "the guest credited no kill although its puppet saw %d deaths: its died events are for the picture" % died_guest)
	check(total == died_host and total > 0 and twice == 0, "the host credited every kill once: %d credited for %d deaths, %d twice" % [total, died_host, twice])
	check(int(kills_host.get(2, 0)) > 0 and int(kills_host.get(1, 0)) > 0 and int(kills_host.get(0, 0)) * 10 <= total, "and the kills are the right players': the guest's (%d, its casts and its thralls) under its peer, the host's (%d) under its own, %d with no hero behind them" % [int(kills_host.get(2, 0)), int(kills_host.get(1, 0)), int(kills_host.get(0, 0))])
	check(absi(died_guest - died_host) <= 3, "the guest's puppet saw the host's deaths (%d against %d)" % [died_guest, died_host])
	var guest_id := gb_h.core_id
	var legion := h.core_host.thrall_count(guest_id)
	g.party.leave()
	check(await until(func() -> bool: return h.session.get_roster().size() == 1 and h.net.guests().is_empty(), 6.0), "the guest left: the host's roster is one again and nothing is sent")
	await ticks(10)
	check(legion > 0 and h.core_host.thrall_count(guest_id) == 0, "its legion left with it (%d thralls)" % legion)
	check(h.core_host.core.replication_stats()["replicating"] == false, "the host stopped collecting events for guests")
	check(g.party.mode == DmNextParty.SOLO or g.party.mode == DmNextParty.CLIENT, "the guest's party state is not stuck (%s)" % g.party.mode)
	h.party.leave()
	check(h.party.mode == DmNextParty.SOLO and h.session.is_host(), "the host stopped hosting and plays on solo")
