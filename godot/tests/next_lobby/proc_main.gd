extends SceneTree
## One player of tests/next_lobby/proc_run.gd as its OWN process: the real DmMain (front skipped), the real HUD adapter, the offline backend of this
## process (a joiner's backend is therefore a different one from the host's: its backend join is refused, which the test asserts), the lobby
## service given by `--lobby=<ws url>` and the login token by the DM_LOBBY_TOKEN environment variable.
##   godot --headless --path godot --script res://tests/next_lobby/proc_main.gd -- <role> <dir> <name> --next --class=2 --lobby=<url>
## Writes <dir>/status_<name>.json ~10x/s and obeys <dir>/cmd_<name>.json = {seq, cmd, ...}:
##   host{name,private} join_code{code} join_id{id} list leave open{on} kick{id} chat{text} move{x,z} spawn{n} quit

var role := ""
var dir := ""
var nm := ""
var m: DmMain
var api: DmApi
var _acc := 0.0
var _last_seq := 0
var _slice: DmNextGame
var _toasts: Array = []
var _swaps := 0


func _initialize() -> void:
	_boot.call_deferred()


func _boot() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	role = a[0]
	dir = a[1]
	nm = a[2]
	var mock := DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	if role == "joiner":   # a different character id from the host's (both processes have their own backend, ids start at 1)
		var r := await api.register("dummy", "d@example.com", "pw1234")
		api.set_token(r.data["token"])
		await api.load_or_create_character(1)
	m = DmMain.new()
	m.mode = "test"
	m.persist_token = false
	m.api = api
	root.add_child(m)


func _status() -> void:
	var s := m.slice if m != null else null
	var st := {"ready": false, "slice": 0, "swaps": _swaps, "toasts": _toasts}
	if s != null:
		if s != _slice:
			_slice = s
			_swaps += 1
			_watch(s)
		st["ready"] = s.ready_
		st["slice"] = s.get_instance_id()
		st["hud"] = s.ui_host != null
		var p := s.party
		if p != null:
			st["mode"] = String(p.mode)
			st["code"] = p.code
			st["err"] = p.last_error
			st["sessions"] = p.sessions
			st["chat"] = p.chat_log
			st["info"] = p.info
			var lob: DmLobbyClient = p.lobby
			if lob == null and p._relay != null:
				lob = p._relay.get_lobby()
			if lob != null:
				st["out"] = lob.bytes_out
				st["pout"] = lob.packets_out
				st["in"] = lob.bytes_in
				st["pin"] = lob.packets_in
		if s.session.is_active():
			st["my_id"] = s.session.get_my_id()
			var roster := []
			for r in s.session.get_roster():
				roster.append({"id": r["peer_id"], "name": r["name"]})
			st["roster"] = roster
			var bodies := {}
			for b in s.session.get_bodies():
				bodies[str(b.owner_peer)] = [b.position.x, b.position.z]
			st["bodies"] = bodies
		if s.rewards != null:
			var mem := {}
			for k in s.rewards.members:
				var mm: DmRewardsMember = s.rewards.members[k]
				mem[str(k)] = {"remote": mm.remote, "blocked": mm.blocked, "peer": mm.peer_id}
			st["members"] = mem
			st["enemies"] = s.director.alive_count()
		if s.joiner != null:
			st["backend_ok"] = s.joiner.backend_ok
	st["fps"] = Engine.get_frames_per_second()
	var f := FileAccess.open("%s/status_%s.tmp" % [dir, nm], FileAccess.WRITE)
	f.store_string(JSON.stringify(st))
	f.close()
	DirAccess.rename_absolute("%s/status_%s.tmp" % [dir, nm], "%s/status_%s.json" % [dir, nm])


func _watch(s: DmNextGame) -> void:
	var hook := func() -> void:
		if s.ui_host != null:
			s.ui_host.game_event.connect(func(id: String, ctx: Dictionary) -> void:
				if id == "toast":
					_toasts.append(String(ctx.get("text", ""))))
	if s.ui_host != null:
		hook.call()
	else:
		s.started.connect(hook)


func _cmd() -> bool:
	var p := "%s/cmd_%s.json" % [dir, nm]
	if not FileAccess.file_exists(p):
		return false
	var c: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if typeof(c) != TYPE_DICTIONARY or int(c.get("seq", 0)) <= _last_seq:
		return false
	_last_seq = int(c["seq"])
	var s := m.slice
	if s == null:
		return false
	var ui := s.ui_host
	match String(c["cmd"]):
		"host":
			ui.party_create(String(c.get("name", "")), bool(c.get("private", true)))
		"join_code":
			ui.party_join(String(c["code"]))
		"join_id":
			ui.party_join_id(String(c["id"]), String(c.get("code", "")))
		"list":
			ui.party_watch(true)
		"unwatch":
			ui.party_watch(false)
		"leave":
			ui.party_leave()
		"open":
			ui.party_set_open(bool(c["on"]))
		"kick":
			ui.party_kick(int(c["id"]))
		"chat":
			ui.send_chat(String(c["text"]))
		"move":
			s.session.request_move_to(Vector3(float(c["x"]), 0, float(c["z"])))
		"spawn":
			var b := s.local_body()   # as tests/next/run.gd's perf part: the hero in the Graves, waves off, a ring of robbers
			b.teleport(Vector3(0, 0, -16))
			s.director.enabled = false
			s.director.clear()
			for i in int(c["n"]):
				s.director.spawn("robber", Vector3(sin(i * 0.5) * 11.0, 0.0, -16.0 + cos(i * 0.5) * 11.0), [b])
		"quit":
			return true
	return false


func _process(delta: float) -> bool:
	_acc += delta
	if _acc < 0.1 or m == null:
		return false
	_acc = 0.0
	_status()
	return _cmd()
