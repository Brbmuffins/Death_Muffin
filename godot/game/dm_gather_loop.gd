class_name DmGatherLoop
extends RefCounted
## Port of `GatherLoop` in src/gameplay/Gathering.ts. Click -> walk to the node's ring -> face -> loop the gesture -> roll each cycle for
## feel -> batch the cycles to the server -> adopt its answer. Auto moves to the nearest live node of the same kind when this one depletes.
##
## `hooks` is the TS GatherHooks as a Dictionary (same keys):
##   now: Callable() -> float (ms)          rand: Callable() -> float in [0,1)
##   nav: DmNav                             player: DmPlayer (x, z, has_path(), move_along(path), face(x, z), stop())
##   nodes: Callable() -> Array of node Dictionaries {id,type,x,z,area,remaining}   live: Callable(id) -> bool
##   bagFits: Callable(item_id) -> bool     sendSuccess: Callable(node_id)
##   post: Callable(node_type, actions, keepalive, afk) -> DmResult (awaitable; see api_post())
##   onCycle: Callable(def, success, node)  onReply: Callable(reply: Dictionary)
##   onStop: Callable(reason, message)      onError: Callable(message)     autoEnabled: Callable() -> bool
## Nodes are Dictionaries (NodePlacement: id, type, x, z, area, rot, rich). TS `null` node = `{}`; a refusal String "" = null (go).
## Timers are driven by update(dt) (dt in seconds) and `now`; there are no SceneTree timers.

const WORK_SLACK := 1.0    # how far past the stand ring the hero may drift before work stops

signal flush_done

var hooks: Dictionary
var skills: DmSkills
var node: Dictionary = {}
var afk := false

var _last_stop := "Paused"
var _phase := "walk"        # walk | work | wait
var _cycle_t := 0.0
var _spot: Dictionary = {}
var _queue: Dictionary = {}   # node type -> cycles (insertion order, like the TS Map)
var _last_flush := 0.0
var _in_flight := false
var _pending := false
var _retry_at := 0.0


func _init(hooks_: Dictionary, skills_: DmSkills) -> void:
	hooks = hooks_
	skills = skills_


## A `post` hook that goes through DmApi (keepalive is a browser tab-close detail and is ignored).
static func api_post(api: DmApi, character_id: int) -> Callable:
	return func(node_type: String, actions: int, _keepalive: bool, afk_: bool) -> DmResult:
		return await api.gather(character_id, node_type, actions, afk_)


var active: bool:
	get: return not node.is_empty()

var working: bool:
	get: return not node.is_empty() and _phase == "work"

var phase: String:
	get: return _phase

var status: String:
	get:
		if node.is_empty():
			return _last_stop
		var what := "Waiting for respawn" if _phase == "wait" else ("Walking to" if _phase == "walk" else "Working")
		return "%s: %s" % [what, DmGathering.node_def(node["type"])["name"]]

## 0..1 progress through the current work cycle (progress arc).
var progress: float:
	get:
		if node.is_empty() or _phase != "work":
			return 0.0
		return minf(1.0, _cycle_t / float(DmGathering.action_ms(DmGathering.node_def(node["type"]))))


func start_afk(n: Dictionary) -> String:
	var refusal := start(n)
	if refusal == "":
		afk = true
	return refusal


## Start working a node (a click, or Auto). Returns a player-readable refusal, or "".
func start(n: Dictionary) -> String:
	var def := DmGathering.node_def(n["type"])
	var block := DmGathering.gather_blocker(n["type"], skills.gate_level(str(def["skill"]) if not def.is_empty() else "woodcutting"))
	if block != "":
		return block
	if not hooks["bagFits"].call(def["item"]):
		return "Your bag is full."
	if not hooks["live"].call(n["id"]):
		return _start_waiting(n)
	var player = hooks["player"]
	var nav: DmNav = hooks["nav"]
	var spot := DmGathering.stand_spot(nav.blocked, n, player.x, player.z)
	if spot.is_empty():
		return "You cannot reach that."
	node = n
	_spot = spot
	_cycle_t = 0.0
	if DmSimMath.hypot(spot["x"] - player.x, spot["z"] - player.z) < 0.35:
		_begin_work()
	else:
		_phase = "walk"
		player.move_along(nav.find_path(player.x, player.z, spot["x"], spot["z"]))
	return ""


func _start_waiting(n: Dictionary) -> String:
	var player = hooks["player"]
	var nav: DmNav = hooks["nav"]
	node = n
	_phase = "wait"
	_spot = DmGathering.stand_spot(nav.blocked, n, player.x, player.z)
	if not _spot.is_empty():
		player.move_along(nav.find_path(player.x, player.z, _spot["x"], _spot["z"]))
	return ""


func _begin_work() -> void:
	_phase = "work"
	_cycle_t = 0.0
	var player = hooks["player"]
	player.stop()
	player.face(node["x"], node["z"])


func stop(reason: String, message: String = "") -> void:
	if node.is_empty():
		return
	node = {}
	_spot = {}
	_last_stop = "Bag full — make room, then Start AFK again." if reason == "bagFull" else (message if message != "" else "Paused")
	hooks["onStop"].call(reason, message)
	flush()    # not awaited: runs up to its first await now, so the batch still sees afk == true (as in the TS)
	afk = false


func update(dt: float) -> void:
	var now: float = hooks["now"].call()
	if not _queue.is_empty() and not _in_flight and now >= _retry_at and (now - _last_flush >= DmGathering.GATHER_FLUSH_MS or _queued_total() >= DmGathering.GATHER_MAX_BATCH):
		flush()
	if node.is_empty():
		return
	var n := node
	var def := DmGathering.node_def(n["type"])
	var player = hooks["player"]
	if not hooks["bagFits"].call(def["item"]):
		stop("bagFull")
		return
	if _phase == "walk" or _phase == "wait":
		if player.has_path():
			return
		var d := DmSimMath.hypot(_spot["x"] - player.x, _spot["z"] - player.z) if not _spot.is_empty() else INF
		if d > 0.6:
			stop("unreachable", "You cannot reach that.")
			return
		if _phase == "wait":
			player.face(n["x"], n["z"])
			if hooks["live"].call(n["id"]):
				_begin_work()
			return
		_begin_work()
		return
	# Working. Safety net: the hero must still be standing at the node (see the TS).
	var reach: float = float(DmGatherData.get_data()["node_reach"][def["kind"]])
	if player.has_path() or DmSimMath.hypot(n["x"] - player.x, n["z"] - player.z) > reach + WORK_SLACK:
		stop("moved")
		return
	if not hooks["live"].call(n["id"]):
		_on_depleted(n)
		return
	_cycle_t += dt * 1000.0
	var cycle_ms := float(DmGathering.action_ms(def))
	if _cycle_t < cycle_ms:
		return
	_cycle_t -= cycle_ms
	_queue[n["type"]] = int(_queue.get(n["type"], 0)) + 1
	var success: bool = float(hooks["rand"].call()) < DmGathering.success_chance(def, maxi(int(def["level"]), skills.level(str(def["skill"]))))
	if success:
		skills.add_pending(str(def["skill"]), int(def["xp"]))
		hooks["sendSuccess"].call(n["id"])
	hooks["onCycle"].call(def, success, n)


func _on_depleted(n: Dictionary) -> void:
	var def := DmGathering.node_def(n["type"])
	if afk or hooks["autoEnabled"].call():
		var player = hooks["player"]
		var nxt := DmGathering.next_auto_node(n, hooks["nodes"].call(), skills.gate_level(str(def["skill"])), player.x, player.z)
		if not nxt.is_empty():
			var refusal := start(nxt)
			if refusal != "":
				stop("blocked", refusal)
			return
		# Nothing else live of this kind: wait here for it to come back.
		_phase = "wait"
		return
	stop("blocked", "The %s is spent." % def["name"])


func _queued_total() -> int:
	var n := 0
	for v in _queue.values():
		n += int(v)
	return n


## Send queued cycles (one request per node type). Awaitable.
func flush(keepalive: bool = false) -> void:
	if _pending:
		# Tab closing with a batch already out: send what queued since instead of skipping it.
		if keepalive and not _queue.is_empty():
			await _flush_batch(true, true)
		while _pending:
			await flush_done
		return
	_pending = true
	await _flush_batch(keepalive)
	_pending = false
	flush_done.emit()


func _flush_batch(keepalive: bool, alongside: bool = false) -> void:
	if (_in_flight and not alongside) or _queue.is_empty():
		return
	var owned := not alongside
	if owned:
		_in_flight = true
	_last_flush = hooks["now"].call()
	var batch: Array = []
	for k in _queue:
		batch.append([k, int(_queue[k])])
	var afk_now := afk
	_queue.clear()
	for entry in batch:
		var type: String = entry[0]
		var left: int = entry[1]
		while left > 0:
			var actions := mini(DmGathering.GATHER_MAX_BATCH, left)
			var res: DmResult = await hooks["post"].call(type, actions, keepalive, afk_now)
			if res.ok:
				var reply: Dictionary = res.data
				skills.adopt(reply.get("skills", []), str(reply.get("skill", "")))
				hooks["onReply"].call(reply)
			else:
				if res.status == 0 or res.status >= 500:
					# Offline or server hiccup: keep the cycles and retry later.
					_queue[type] = int(_queue.get(type, 0)) + left
					_retry_at = float(hooks["now"].call()) + 10000.0
					break
				# A refusal (level, budget, unknown node) is final for these cycles; the server's words are player-readable.
				var def := DmGathering.node_def(type)
				if not def.is_empty():
					skills.adopt([], str(def["skill"]))
				hooks["onError"].call(res.error if res.error != "" else "Gathering failed")
				break
			left -= DmGathering.GATHER_MAX_BATCH
	if owned:
		_in_flight = false
