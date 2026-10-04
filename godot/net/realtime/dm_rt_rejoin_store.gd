class_name DmRtRejoinStore
extends RefCounted
## Port of src/net/rejoinStore.ts: the co-op world code is remembered for 10 minutes so a restart rejoins the same party.
## The web keeps it in sessionStorage; here it lives in a static (per process). Call save_to_file/load_from_file for a restart.
const WINDOW_MS := 10 * 60 * 1000
const FILE := "user://coop_rejoin.json"

static var _code: String = ""
static var _t: int = -1

static func save_rejoin(code: String, now_ms: int = -1) -> void:
	_code = code
	_t = Time.get_ticks_msec() if now_ms < 0 else now_ms

## The code saved within the last 10 minutes, or "".
static func load_rejoin(now_ms: int = -1) -> String:
	if _code.is_empty() or _t < 0:
		return ""
	var now := Time.get_ticks_msec() if now_ms < 0 else now_ms
	var age := now - _t
	return _code if age >= 0 and age <= WINDOW_MS else ""

static func clear_rejoin() -> void:
	_code = ""
	_t = -1
