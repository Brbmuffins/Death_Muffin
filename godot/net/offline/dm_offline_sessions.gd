class_name DmOfflineSessions
extends RefCounted
## The offline edition's half of the party-session API (server/death-muffin/backend/SESSION-REPORTS.md, decision D4). Same routes, payloads,
## codes and membership rules as party-sessions.cjs, so an offline solo session reports through the identical client path. There is no kill
## ledger offline (nothing of value leaves the device), so accepted counts are the claimed counts; everything else (host-only reports,
## attached members only, heartbeats, idempotent batches, bounds, ended/left refusals) is the same. State is in memory: a session is a
## play-session, not a save. The mock calls `handle` for every /api/sessions request.

const MAX_MEMBERS := 4
const HEARTBEAT_TTL_MS := 120000
const HEARTBEAT_MIN_MS := 5000
const SESSION_IDLE_MS := 600000
const MAX_GROUPS_PER_MEMBER := 80
const MAX_BOSSES_PER_MEMBER := 12

var _sessions: Dictionary = {}
var _counter := 0

static func _fail(status: int, code: String, msg: String) -> Dictionary:
	return {"status": status, "body": {"success": false, "code": code, "error": msg}}

static func _ok(data: Variant) -> Dictionary:
	return {"status": 200, "body": {"success": true, "data": data}}

func _live(s: Dictionary, now: int) -> bool:
	return s["status"] == "open" and now - int(s["last_host_at"]) <= SESSION_IDLE_MS

func _view(s: Dictionary, now: int) -> Dictionary:
	var ms: Array = []
	for cid in s["members"]:
		var m: Dictionary = s["members"][cid]
		ms.append({"characterId": int(cid), "status": m["status"], "joinedAt": m["joined_at"], "lastSeenAt": m["last_seen_at"],
			"reportedKills": m["reported"], "acceptedKills": m["accepted"], "acceptedBosses": m["bosses"]})
	return {"sessionId": s["id"], "status": "open" if _live(s, now) else "ended", "hostCharacterId": s["host_char"], "createdAt": s["created_at"],
		"lastBatch": s["last_batch"], "batches": s["batches"], "members": ms,
		"limits": {"maxMembers": MAX_MEMBERS, "heartbeatTtlMs": HEARTBEAT_TTL_MS, "heartbeatMinMs": HEARTBEAT_MIN_MS, "idleMs": SESSION_IDLE_MS}}

func _active_count(s: Dictionary) -> int:
	var n := 0
	for cid in s["members"]:
		if s["members"][cid]["status"] == "active":
			n += 1
	return n

## account: the caller's account key; owner_of: Callable(character_id:int) -> account key ("" = no such character).
func handle(method: String, path: String, body: Dictionary, account: String, owner_of: Callable, now: int) -> Dictionary:
	var parts := path.trim_prefix("/api/sessions").trim_prefix("/").split("/", false)
	if parts.is_empty():
		if method == "POST":
			return _open(body, account, owner_of, now)
		return _fail(404, "no_route", "Offline backend: no route for %s %s" % [method, path])
	var sid := String(parts[0])
	if sid.length() != 32 or not sid.is_valid_hex_number(false):
		return _fail(400, "bad_request", "invalid session")
	var s: Variant = _sessions.get(sid)
	if s == null:
		return _fail(404, "no_session", "session not found")
	var sess: Dictionary = s
	var action := String(parts[1]) if parts.size() > 1 else ""
	if method == "GET" and action == "":
		if sess["host_account"] != account and not _has_account(sess, account):
			return _fail(403, "not_member", "You are not in that session.")
		return _ok(_view(sess, now))
	if method != "POST":
		return _fail(404, "no_route", "Offline backend: no route for %s %s" % [method, path])
	match action:
		"join": return _join(sess, body, account, owner_of, now)
		"heartbeat": return _heartbeat(sess, body, account, now)
		"leave": return _leave(sess, body, account)
		"report": return _report(sess, body, account, now)
		"end": return _end(sess, body, account, now)
	return _fail(404, "no_route", "Offline backend: no route for POST %s" % path)

func _has_account(s: Dictionary, account: String) -> bool:
	for cid in s["members"]:
		if s["members"][cid]["account"] == account:
			return true
	return false

func _cid(body: Dictionary) -> int:
	var v: Variant = body.get("characterId")
	return int(v) if (v is int or v is float) else 0

func _open(body: Dictionary, account: String, owner_of: Callable, now: int) -> Dictionary:
	var cid := _cid(body)
	if cid <= 0:
		return _fail(400, "bad_request", "invalid characterId")
	if String(owner_of.call(cid)) != account:
		return _fail(403, "not_owner", "character not found or not owned by this account")
	for k in _sessions:
		var o: Dictionary = _sessions[k]
		if o["host_account"] == account and o["status"] == "open":
			o["status"] = "ended"
	_leave_all(cid, now)
	_counter += 1
	var id := ("%016x%016x" % [now, _counter * 2654435761 + 40503]).substr(0, 32)
	var s := {"id": id, "host_account": account, "host_char": cid, "status": "open", "created_at": now, "last_host_at": now,
		"last_batch": 0, "batches": 0, "members": {}, "summary": {}}
	s["members"][cid] = _member(account, now)
	_sessions[id] = s
	return _ok(_view(s, now))

func _member(account: String, now: int) -> Dictionary:
	return {"account": account, "status": "active", "joined_at": now, "last_seen_at": now, "seen": 0, "reported": 0, "accepted": 0, "bosses": 0}

func _leave_all(cid: int, _now: int) -> void:
	for k in _sessions:
		var m: Variant = _sessions[k]["members"].get(cid)
		if m != null and m["status"] == "active":
			m["status"] = "left"

func _join(s: Dictionary, body: Dictionary, account: String, owner_of: Callable, now: int) -> Dictionary:
	var cid := _cid(body)
	if cid <= 0:
		return _fail(400, "bad_request", "invalid session or character")
	if String(owner_of.call(cid)) != account:
		return _fail(403, "not_owner", "character not found or not owned by this account")
	if not _live(s, now):
		return _fail(409, "session_ended", "That session has ended.")
	var mine: Variant = s["members"].get(cid)
	if mine != null and mine["status"] == "left":
		return _fail(409, "left", "This character left the session and cannot rejoin it.")
	if mine == null:
		if _active_count(s) >= MAX_MEMBERS:
			return _fail(409, "full", "A session holds %d players." % MAX_MEMBERS)
		_leave_all(cid, now)
		s["members"][cid] = _member(account, now)
	return _ok(_view(s, now))

func _heartbeat(s: Dictionary, body: Dictionary, account: String, now: int) -> Dictionary:
	var cid := _cid(body)
	if cid <= 0:
		return _fail(400, "bad_request", "invalid session or character")
	if not _live(s, now):
		return _fail(409, "session_ended", "That session has ended.")
	var m: Variant = s["members"].get(cid)
	if m == null or m["account"] != account:
		return _fail(403, "not_member", "This character is not in that session.")
	if m["status"] == "left":
		return _fail(409, "left", "This character left the session.")
	if now - int(m["last_seen_at"]) < HEARTBEAT_MIN_MS:
		return _ok({"throttled": true})
	m["last_seen_at"] = now
	var seen: Variant = body.get("kills")
	if seen is int or seen is float:
		m["seen"] = maxi(int(m["seen"]), clampi(int(seen), 0, 10000000))
	return _ok({"ok": true, "status": "open"})

func _leave(s: Dictionary, body: Dictionary, account: String) -> Dictionary:
	var cid := _cid(body)
	var m: Variant = s["members"].get(cid)
	if cid <= 0 or m == null:
		return _fail(403, "not_member", "This character is not in that session.")
	if s["host_account"] != account and m["account"] != account:
		return _fail(403, "not_member", "This character is not in that session.")
	if cid == int(s["host_char"]):
		return _fail(400, "host_cannot_leave", "The host ends the session instead of leaving it.")
	m["status"] = "left"
	return _ok({"left": true})

## Shape check shared with the server: returns an error string ("" = fine).
static func parse_report(body: Dictionary) -> String:
	var b: Variant = body.get("batch")
	if not (b is int or b is float) or int(b) < 1 or int(b) > 1000000000:
		return "batch must be a positive integer"
	var entries: Variant = body.get("members")
	if not (entries is Array) or entries.is_empty():
		return "members must be a non-empty array"
	if entries.size() > MAX_MEMBERS:
		return "at most %d members per report" % MAX_MEMBERS
	var seen := {}
	for e in entries:
		if not (e is Dictionary):
			return "each member needs a distinct characterId"
		var id: Variant = e.get("characterId")
		if not (id is int or id is float) or int(id) <= 0 or seen.has(int(id)):
			return "each member needs a distinct characterId"
		seen[int(id)] = true
		if (e.get("groups", []) is Array and e.get("groups", []).size() > MAX_GROUPS_PER_MEMBER) or (e.get("bosses", []) is Array and e.get("bosses", []).size() > MAX_BOSSES_PER_MEMBER):
			return "member report too large"
	return ""

func _report(s: Dictionary, body: Dictionary, account: String, now: int) -> Dictionary:
	var err := parse_report(body)
	if err != "":
		return _fail(400, "bad_request", err)
	if s["host_account"] != account:
		return _fail(403, "not_host", "Only the session host reports for it.")
	if not _live(s, now):
		return _fail(409, "session_ended", "That session has ended.")
	var batch := int(body["batch"])
	if batch <= int(s["last_batch"]):
		return _ok({"batch": batch, "duplicate": true, "members": []})
	s["last_batch"] = batch
	s["batches"] = int(s["batches"]) + 1
	s["last_host_at"] = now
	s["members"][s["host_char"]]["last_seen_at"] = now
	var out: Array = []
	for e in body["members"]:
		var cid := int(e["characterId"])
		var r := {"characterId": cid, "credited": false}
		out.append(r)
		var m: Variant = s["members"].get(cid)
		if m == null:
			r["reason"] = "not_member"
			continue
		if m["status"] != "active":
			r["reason"] = "left"
			continue
		if cid != int(s["host_char"]) and now - int(m["last_seen_at"]) > HEARTBEAT_TTL_MS:
			r["reason"] = "stale_heartbeat"
			continue
		var claimed := 0
		for g in e.get("groups", []):
			if g is Dictionary and (g.get("n") is int or g.get("n") is float):
				claimed += clampi(int(g["n"]), 0, 6000)
		var bosses := 0
		for b in e.get("bosses", []):
			if b is Dictionary and (b.get("n") is int or b.get("n") is float):
				bosses += clampi(int(b["n"]), 0, 20)
		if e.get("floors") is Array and not e["floors"].is_empty():
			r["floorsDropped"] = e["floors"].size()
		r["credited"] = true
		r["mode"] = "offline"
		r["claimedKills"] = claimed
		r["accepted"] = {"kills": claimed, "bosses": bosses}
		m["reported"] = int(m["reported"]) + claimed
		m["accepted"] = int(m["accepted"]) + claimed
		m["bosses"] = int(m["bosses"]) + bosses
	return _ok({"batch": batch, "mode": "offline", "members": out})

func _end(s: Dictionary, body: Dictionary, account: String, now: int) -> Dictionary:
	if s["host_account"] != account:
		return _fail(403, "not_host", "Only the session host ends it.")
	if s["status"] == "ended":
		return _ok({"ended": true, "already": true})
	var final: Variant = null
	if body.has("batch") or body.has("members"):
		var r := _report(s, body, account, now)
		if int(r["status"]) >= 400 and r["body"].get("code") != "session_ended":
			return r
		final = r["body"].get("data")
	s["status"] = "ended"
	var sm: Variant = body.get("summary")
	if sm is Dictionary:
		for k in sm:
			if (sm[k] is int or sm[k] is float) and String(k).length() <= 32:
				s["summary"][k] = sm[k]
	var ms: Array = _view(s, now)["members"]
	var data := {"ended": true, "members": ms}
	if final != null:
		data["final"] = final
	return _ok(data)
