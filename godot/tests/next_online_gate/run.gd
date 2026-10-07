extends SceneTree
## D10 staff-only online (front flow + DmOnlineGate): godot --headless --path godot --script res://tests/next_online_gate/run.gd
## A scripted transport plays the server (manifest, /login, /api/me, /character): no network. Checks that a denied account is returned to the
## login screen with the manifest message and that NO character / claim route was touched, that staff get in, and that every odd manifest fails closed.

var passed := 0
var failed := 0
var manifest_text := ""
var manifest_status := 200
var staff_ids := {7: true}
var account := 7           # which account the next /login signs in as
var log_: Array = []       # "METHOD path" per request


func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)

func _transport(req: Dictionary) -> Dictionary:
	var url := String(req["url"])
	var path := url.trim_prefix(DmConfig.API_BASE)
	log_.append("%s %s" % [req["method"], path if url.begins_with(DmConfig.API_BASE) else url])
	if url == DmConfig.CLIENT_MANIFEST_URL:
		return {"status": manifest_status, "text": manifest_text}
	if path == "/login":
		return {"status": 200, "text": JSON.stringify({"token": "tok-%d" % account})}
	var auth := String(req["headers"].get("Authorization", ""))
	var id := int(auth.trim_prefix("Bearer tok-")) if auth.begins_with("Bearer tok-") else 0
	if path == "/api/me":
		if id == 0:
			return {"status": 401, "text": "{}"}
		return {"status": 200, "text": JSON.stringify({"success": true, "username": "Brbmuffins", "staff": staff_ids.has(id)})}
	if path == "/api/session/claim":
		return {"status": 200, "text": JSON.stringify({"token": auth.trim_prefix("Bearer ")})}
	if path == "/character" and req["method"] == "GET":
		return {"status": 200, "text": JSON.stringify({"id": 1, "class_index": 2, "level": 1})}
	return {"status": 404, "text": "{}"}

func _count(prefix: String) -> int:
	return log_.filter(func(l: String) -> bool: return l.begins_with(prefix)).size()

func _touched_character() -> bool:
	return log_.any(func(l: String) -> bool: return " /character" in l or "/api/session/claim" in l)

## A flow on a fresh api; returns it in the tree at the login screen (or resumed when `stored` token is set).
func _flow(stored: String = "") -> DmFrontFlow:
	log_.clear()
	var api := DmApi.new(Callable(self, "_transport"))
	api.persist_token = false
	if not stored.is_empty():
		api.set_token(stored)
	var f := DmFrontFlow.new(api, false, false)
	f.persist_token = false
	f.online_gate = true
	root.add_child(f)
	if stored.is_empty():
		f.start()   # no token: straight to the login screen
	return f

func _login(f: DmFrontFlow, id: int) -> void:
	account = id
	var l := f.current as DmLoginScreen
	l.user_edit.text = "someone"
	l.pass_edit.text = "pw"
	await l.submit()
	for i in 6:
		await process_frame

func _entered(f: DmFrontFlow) -> Array:
	var box := []
	f.enter_world.connect(func(c, _s) -> void: box.append(c))
	return box

func _denied(f: DmFrontFlow, msg: String, what: String) -> void:
	check(f.current_name == "login" and f.current is DmLoginScreen, what + ": back at the login screen")
	check(f.api.get_token().is_empty(), what + ": session dropped")
	check(not _touched_character(), what + ": no character / claim route touched (%s)" % str(log_))
	if f.current is DmLoginScreen:
		check(f.current.error_label.text == msg, what + ": message '%s' (got '%s')" % [msg, f.current.error_label.text])

func _set_manifest(online: Variant) -> void:
	manifest_status = 200
	manifest_text = JSON.stringify({"version": "x", "files": [], "online": online} if online != null else {"version": "x"})


func _run() -> void:
	# ---- parse: old shape stays locked, only literal true counts, message sanitised
	var g := DmOnlineGate.parse({"online": {"enabled": false, "message": "Online opens soon"}})
	check(not g["open"] and not g["staff"] and not DmOnlineGate.offered(g), "old manifest shape: locked, not offered")
	g = DmOnlineGate.parse({"online": {"enabled": false, "staff": true, "message": " Staff\npreview "}})
	check(not g["open"] and g["staff"] and DmOnlineGate.offered(g) and g["message"] == "Staff preview", "staff mode: offered, still not open, message one line")
	for bad in [{"enabled": "true"}, {"enabled": 1}, {"staff": "true"}, {"staff": 1}, {}, "x", null]:
		var b := DmOnlineGate.parse({"online": bad})
		check(not b["open"] and not b["staff"], "odd online block stays locked: %s" % str(bad))
	check(not DmOnlineGate.parse({}).get("open") and DmOnlineGate.parse([]).get("message") == DmOnlineGate.LOCKED_MESSAGE, "missing/garbage manifest is locked with the default message")
	check(DmOnlineGate.parse({"online": {"enabled": true}})["open"], "enabled:true opens")

	# ---- locked: everybody (staff too) is turned back, nothing created or loaded
	_set_manifest({"enabled": false, "message": "Online opens soon"})
	var f := _flow()
	await process_frame
	var box := _entered(f)
	await _login(f, 7)
	_denied(f, "Online opens soon", "locked, staff account")
	check(_count("GET " + DmConfig.CLIENT_MANIFEST_URL) == 1 and _count("GET /api/me") == 0 and box.is_empty(), "locked: manifest read once, /api/me not asked, no world")
	f.queue_free()

	# ---- staff mode: non-staff turned back with the same message; the account name decides nothing
	_set_manifest({"enabled": false, "staff": true, "message": "Online opens soon"})
	f = _flow()
	await process_frame
	box = _entered(f)
	await _login(f, 8)
	_denied(f, "Online opens soon", "staff mode, regular account")
	check(_count("GET /api/me") == 1 and box.is_empty(), "staff mode: the backend was asked (/api/me), no world")
	f.queue_free()

	# ---- staff mode: staff account plays (character route reached only after the check)
	f = _flow()
	await process_frame
	box = _entered(f)
	await _login(f, 7)
	check(box.size() == 1 and int(box[0].get("id", 0)) == 1, "staff mode, staff account: enters the world")
	var me_i := log_.find("GET /api/me")
	var ch_i := log_.find("GET /character")
	check(me_i >= 0 and ch_i > me_i, "the staff check came before the character load")
	f.queue_free()

	# ---- stored token (boot path): non-staff is stopped before claim_session / character; staff boots through
	f = _flow("tok-8")
	box = _entered(f)
	f.start()
	for i in 8:
		await process_frame
	_denied(f, "Online opens soon", "stored token, regular account")
	f.queue_free()
	f = _flow("tok-7")
	box = _entered(f)
	f.start()
	for i in 8:
		await process_frame
	check(box.size() == 1 and _count("POST /api/session/claim") == 1, "stored token, staff account: boots into the world")
	f.queue_free()
	f = _flow("tok-0")
	f.start()
	for i in 8:
		await process_frame
	check(f.current_name == "login" and f.current.error_label.text == "Your session ended: sign in again" and not _touched_character(), "stored but invalid token: asked to sign in again")
	f.queue_free()

	# ---- open to everybody: no staff lookup
	_set_manifest({"enabled": true, "message": "x"})
	f = _flow()
	await process_frame
	box = _entered(f)
	await _login(f, 8)
	check(box.size() == 1 and _count("GET /api/me") == 0, "open: a regular account plays, no /api/me")
	f.queue_free()

	# ---- fail closed: unreachable / garbage manifest, string staff flag, /api/me refusing
	for case in [["unreachable", func() -> void: manifest_status = 503; manifest_text = ""],
			["garbage", func() -> void: manifest_status = 200; manifest_text = "<html>"],
			["no online block", func() -> void: _set_manifest(null)],
			["staff as string", func() -> void: _set_manifest({"enabled": false, "staff": "true"})]]:
		case[1].call()
		f = _flow()
		await process_frame
		box = _entered(f)
		await _login(f, 7)
		_denied(f, "Online opens soon", "manifest %s" % case[0])
		check(box.is_empty(), "manifest %s: nobody gets in, not even staff" % case[0])
		f.queue_free()

	# ---- offline builds never see the gate (the flow only gates when asked)
	log_.clear()
	var off := DmFrontFlow.new(DmApi.new(Callable(self, "_transport")), true, true)
	check(not off.online_gate and (await off._gate_allows()) and log_.is_empty(), "offline flow: gate off, no requests")
	off.free()

	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
