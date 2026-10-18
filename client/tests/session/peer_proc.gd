extends SceneTree
## One session participant as its own headless process, driven by tests/session/run.gd through files in a shared dir.
## Args (after --): role port dir [name]. role = host | client.  Writes <dir>/status_<name>.json (atomic) ~10x/s and obeys
## <dir>/cmd_<name>.json = {seq, cmd, ...}: move{x,z,body?} | leave | quit.

var role := ""
var nm := ""
var dir := ""
var sess: DmSession
var holder: Node
var events: Array = []
var ended := ""
var started := false
var _last_seq := 0
var _acc := 0.0
var _t0 := 0.0
var _quit := false


func _initialize() -> void:
	_boot.call_deferred()


func _boot() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	role = a[0]
	var port := int(a[1])
	dir = a[2]
	nm = a[3] if a.size() > 3 else role
	_t0 = Time.get_ticks_msec() / 1000.0
	holder = Node.new()
	holder.name = "Holder"
	root.add_child(holder)
	sess = DmSession.new()
	sess.name = "Session"
	holder.add_child(sess)
	sess.character_name = nm
	sess.discipline_id = "disc_" + nm
	sess.session_started.connect(func(): started = true)
	sess.session_ended.connect(func(r): ended = r)
	sess.player_joined.connect(func(id): events.append("joined:%d" % id))
	sess.player_left.connect(func(id): events.append("left:%d" % id))
	var peer := ENetMultiplayerPeer.new()
	if role == "host":
		peer.create_server(port, 8)
		sess.host(peer)
	else:
		peer.create_client("127.0.0.1", port)
		sess.join(peer)


func _status() -> void:
	var bodies := {}
	for b in sess.get_bodies():
		bodies[str(b.owner_peer)] = [b.position.x, b.position.z]
	var ids := []
	for e in sess.get_roster():
		ids.append(e["peer_id"])
	var f := FileAccess.open("%s/status_%s.tmp" % [dir, nm], FileAccess.WRITE)
	f.store_string(JSON.stringify({"my_id": sess.get_my_id(), "started": started, "ended": ended, "roster": ids,
			"roster_full": sess.get_roster(), "bodies": bodies, "events": events, "rejected": sess.rejected_intents}))
	f.close()
	DirAccess.rename_absolute("%s/status_%s.tmp" % [dir, nm], "%s/status_%s.json" % [dir, nm])


func _cmd() -> void:
	var p := "%s/cmd_%s.json" % [dir, nm]
	if not FileAccess.file_exists(p):
		return
	var c: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if typeof(c) != TYPE_DICTIONARY or int(c.get("seq", 0)) <= _last_seq:
		return
	_last_seq = int(c["seq"])
	match c["cmd"]:
		"move":
			sess.request_move_to(Vector3(c["x"], 0, c["z"]), int(c.get("body", 0)))
		"leave":
			sess.leave()
		"quit":
			_quit = true


func _process(delta: float) -> bool:
	if sess == null:
		return false
	_acc += delta
	if _acc >= 0.1:
		_acc = 0.0
		_cmd()
		_status()
	return _quit or Time.get_ticks_msec() / 1000.0 - _t0 > 90.0
