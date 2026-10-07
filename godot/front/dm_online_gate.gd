class_name DmOnlineGate
extends RefCounted
## Who may play online (owner decision D10: staff first). The client manifest's `online` block says:
##   {enabled: true}               everyone
##   {enabled: false, staff: true} staff/GM accounts only (the backend decides: GET /api/me -> staff)
##   anything else / unreadable    nobody ("Online opens soon")
## Only a literal JSON `true` counts. An old client or launcher that reads just `enabled` keeps seeing it locked.

const LOCKED_MESSAGE := "Online opens soon"
const MAX_MESSAGE := 70

## {open, staff, message} from a parsed manifest ({} = unreadable = locked).
static func parse(manifest: Variant) -> Dictionary:
	var out := {"open": false, "staff": false, "message": LOCKED_MESSAGE}
	if not (manifest is Dictionary) or not (manifest.get("online") is Dictionary):
		return out
	var o: Dictionary = manifest["online"]
	out["open"] = o.get("enabled") is bool and o["enabled"]
	out["staff"] = o.get("staff") is bool and o["staff"]
	if o.get("message") is String:
		var m := String(o["message"]).replace("\r", " ").replace("\n", " ").strip_edges()
		if not m.is_empty():
			out["message"] = m.substr(0, MAX_MESSAGE)
	return out

## Whether online is offered at all (launcher-style: enabled, or staff mode on).
static func offered(gate: Dictionary) -> bool:
	return bool(gate.get("open", false)) or bool(gate.get("staff", false))

## Decide for the signed-in `api` session. Returns {allowed, staff, message}. Fails closed: an unreadable manifest, or a /api/me that fails or
## does not say `staff: true` (literal), denies. Open-to-all never calls /api/me. No character endpoint is touched here.
static func check(api: DmApi) -> Dictionary:
	var gate := parse(await api.fetch_client_manifest())
	if gate["open"]:
		return {"allowed": true, "staff": false, "message": ""}
	if not gate["staff"]:
		return {"allowed": false, "staff": false, "message": gate["message"]}
	var me := await api.get_me()
	if me.ok and me.data is Dictionary and me.data.get("staff") is bool and me.data["staff"]:
		return {"allowed": true, "staff": true, "message": ""}
	if me.status == 401:
		return {"allowed": false, "staff": false, "message": "Your session ended: sign in again"}
	return {"allowed": false, "staff": false, "message": gate["message"]}
