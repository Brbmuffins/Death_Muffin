class_name DmProgressSync
extends RefCounted
## The network + persistence half of src/gameplay/progression.ts (DmProgression is the pure state). Server saves happen on level-up,
## periodically while dirty (45 s), on area change and on quit; failures retry with backoff. Necro-progress mutations run one at a time
## so their replies are adopted in the order the server applied them. 'server' mode once the necro-progress routes answered.
## `tick(dt)` drives the timers (the host calls it every frame).

signal save_state_changed(state: String)   # saved | dirty | saving | retrying
signal error(message: String)

var api: DmApi
var prog: DmProgression
var reporter: DmKillReporter = DmKillReporter.new()
var character_id: int = 0
var state: String = "saved"
var persist: bool = true

var _in_flight := false
var _urgent_again := false
var _dirty_server := false
var _timer := -1.0
var _retry_delay := 4.0
var _remote_in_flight := 0
var _queue: Array = []
var _pumping := false
var _local_timer := -1.0
var _local_dirty := false


static func local_path(id: int) -> String:
	return "user://dm_progress_v1_%d.json" % id


func _init(api_: DmApi, prog_: DmProgression, character_id_: int, do_persist: bool = true) -> void:
	api = api_
	prog = prog_
	character_id = character_id_
	persist = do_persist
	prog.changed.connect(_on_prog_changed)


static func load_local(id: int) -> Variant:
	var p := local_path(id)
	if FileAccess.file_exists(p):
		return JSON.parse_string(FileAccess.get_file_as_string(p))
	return null


func _on_prog_changed() -> void:
	_local_dirty = true
	if _local_timer < 0.0:
		_local_timer = 1.5
	_drain_flags()


func save_local_now() -> void:
	_local_timer = -1.0
	_local_dirty = false
	if not persist:
		return
	var f := FileAccess.open(local_path(character_id), FileAccess.WRITE)
	if f:
		f.store_string(prog.to_json())


## Pick up the dirty / urgent flags and the outbox the pure state set.
func _drain_flags() -> void:
	if prog.save_dirty:
		_dirty_server = true
		if state == "saved":
			_set_state("dirty")
		prog.save_dirty = false
		if prog.save_urgent:
			prog.save_urgent = false
			if _in_flight:
				_urgent_again = true
			else:
				flush()
		elif _timer < 0.0:
			_timer = 45.0
	while not prog.outbox.is_empty():
		var job: Dictionary = prog.outbox.pop_front()
		_enqueue(_job_call(job))


func _set_state(s: String) -> void:
	if state != s:
		state = s
		save_state_changed.emit(s)


func tick(dt: float) -> void:
	if not prog.outbox.is_empty() or prog.save_dirty:
		_drain_flags()
	if _local_timer >= 0.0:
		_local_timer -= dt
		if _local_timer <= 0.0:
			save_local_now()
	if _timer >= 0.0:
		_timer -= dt
		if _timer <= 0.0:
			_timer = -1.0
			flush()


# --- connect ---------------------------------------------------------------------------------------------------------------------

## Try the server. 404 / unreachable -> stay local. First contact imports the local save once; after that the server wins.
func connect_server() -> String:
	var r := await api.necro_get(character_id)
	if not r.ok:
		prog.mode = "local"
		return "local"
	var reply: Dictionary = r.data
	var progress: Dictionary = reply.get("progress", {})
	if not progress.get("migrated", false):
		var imp := await api.necro_import_local(character_id, prog.local)
		if imp.ok and imp.data is Dictionary:
			reply = imp.data
			progress = reply.get("progress", progress)
		prog.pending = DmProgression.empty_pending()
		prog.pending_wave_active = false
	prog.mode = "server"
	prog.adopt(progress)
	return "server"


# --- serial queue ----------------------------------------------------------------------------------------------------------------

func _enqueue(call: Callable) -> void:
	if prog.mode != "server":
		return
	_queue.append(call)
	_pump()


func _pump() -> void:
	if _pumping:
		return
	_pumping = true
	while not _queue.is_empty():
		var c: Callable = _queue.pop_front()
		_remote_in_flight += 1
		var r: DmResult = await c.call()
		if r != null and r.ok and r.data is Dictionary and r.data.has("progress"):
			prog.adopt(r.data["progress"])
		elif r != null and not r.ok:
			error.emit(r.error if r.error != "" else "Progress could not be saved")
			var g := await api.necro_get(character_id)
			if g.ok and g.data is Dictionary and g.data.has("progress"):
				prog.adopt(g.data["progress"])
		_remote_in_flight -= 1
	_pumping = false


func _job_call(job: Dictionary) -> Callable:
	match job["type"]:
		"purchase":
			return func() -> DmResult:
				var sent := _payload()
				sent["gold"] = maxi(0, int(job["gold_before"]))
				var sv := await api.save_progress(sent)
				if sv.ok:
					_ack(sent)
				var r := await api.necro_purchase(character_id, job["upgrade"])
				_dirty_server = true
				prog.save_dirty = false
				return r
		"ascend":
			return func() -> DmResult: return await api.necro_ascend(character_id)
		"vows":
			return func() -> DmResult:
				await _send_necro()
				return await api.necro_vows(character_id, job["vows"])
		"unlock":
			return func() -> DmResult:
				await _send_necro()
				return await api.necro_unlock(character_id, job["key"])
		"boon":
			return func() -> DmResult: return await api.necro_boon(character_id, job["id"])
		"summon_prelate":
			return func() -> DmResult:
				await _send_necro()
				return await api.necro_summon_prelate(character_id)
		"summon_boss":
			return func() -> DmResult:
				await _send_necro()
				return await api.necro_summon_boss(character_id, job["boss"])
	return func() -> DmResult: return null


## A gold spend the server prices and takes (reforge, Empowered summons): bring the server's gold up to ours, make the call, adopt the
## gold in its reply keeping anything picked up meanwhile. `call` returns a DmResult whose data has {gold, cost?}.
func spend_on_server(call: Callable) -> DmResult:
	var done := [null]
	_queue.append(func() -> DmResult:
		# `before` is the gold this pre-save SENDS (read before the await): a pickup landing while the save is in flight is then part of
		# `gained`, not of `before` (reading it after the await lost that pickup when the server's gold replaced ours).
		var sent := _payload()
		var before := int(sent["gold"])
		var sv := await api.save_progress(sent)
		if not sv.ok:   # the server would price from stale gold, and its reply would overwrite our unsaved gold
			done[0] = sv
			return null
		_ack(sent)
		var r: DmResult = await call.call()
		if r.ok and r.data is Dictionary:
			var gained := int(prog.character.get("gold", 0)) - before
			prog.character["gold"] = maxi(0, int(r.data.get("gold", 0)) + gained)
			if r.data.get("cost", 0):
				if prog.chronicle != null:
					prog.chronicle.add("gold.spent", int(r.data["cost"]))
			if gained != 0:
				prog.save_dirty = true
			prog.changed.emit()
		done[0] = r
		return null)
	_pump()
	while done[0] == null:
		await Engine.get_main_loop().process_frame
	return done[0]


# --- saves -----------------------------------------------------------------------------------------------------------------------

func _payload() -> Dictionary:
	var c: Dictionary = prog.character
	var reports := reporter.batches()
	var d := {
		"characterId": character_id,
		"level": int(c.get("level", 1)),
		"xp": int(c.get("experience", 0)),
		"gold": maxi(0, DmProgUtil.js_round(float(c.get("gold", 0)))),
		"stat_str": int(c.get("stat_str", 5)), "stat_agi": int(c.get("stat_agi", 5)),
		"stat_int": int(c.get("stat_int", 5)), "stat_vit": int(c.get("stat_vit", 5)),
	}
	if not reports.is_empty():
		d["killReports"] = reports
	return d


func _ack(sent: Dictionary) -> void:
	var reports: Variant = sent.get("killReports")
	if reports is Array and not (reports as Array).is_empty():
		reporter.ack(int(reports[reports.size() - 1]["seq"]))


## Post whatever the reporter holds on its own. Never fails loudly: a failure keeps the batches for the next save.
func flush_reports() -> void:
	var reports := reporter.batches()
	if reports.is_empty():
		return
	var r := await api.report_kills(character_id, reports)
	if r.ok:
		reporter.ack(int(reports[reports.size() - 1]["seq"]))
	elif r.status == 404 or r.status == 400:
		reporter.discard()


func report_floor(f: Dictionary) -> void:
	reporter.floor_clear(f)
	flush_reports()


func report_kill(k: Dictionary) -> void:
	reporter.kill(k)
	if reporter.crowded():
		flush_reports()


func _has_pending() -> bool:
	var p: Dictionary = prog.pending
	if prog.pending_wave_active or int(p["shards"]) > 0 or int(p["prelateKills"]) > 0:
		return true
	for a in p["areaKills"]:
		if int(p["areaKills"][a]) > 0:
			return true
	return false


func _send_necro() -> bool:
	if prog.mode != "server" or not _has_pending():
		return true
	if reporter.has_pending():
		await flush_reports()
	var sent: Dictionary = prog.pending
	var wave := prog.pending_wave_active
	prog.pending = DmProgression.empty_pending()
	prog.pending_wave_active = false
	var input: Dictionary = sent.duplicate(true)
	if wave:
		input["waveTierActive"] = prog.local["waveTierActive"]
	var r := await api.necro_save(character_id, input)
	if r.ok and r.data is Dictionary and r.data.has("progress"):
		prog.adopt(r.data["progress"])
		return true
	for a in sent["areaKills"]:
		prog.pending["areaKills"][a] = int(prog.pending["areaKills"].get(a, 0)) + int(sent["areaKills"][a])
	prog.pending["shards"] += int(sent["shards"])
	prog.pending["prelateKills"] += int(sent["prelateKills"])
	prog.pending["peakWaveTier"] = maxi(int(prog.pending["peakWaveTier"]), int(sent["peakWaveTier"]))
	prog.pending_wave_active = prog.pending_wave_active or wave
	return false


## The regular save: level / xp / gold / stats (with kill batches), then the necro deltas.
func flush(keepalive: bool = false) -> void:
	_timer = -1.0
	if not _dirty_server or api == null:
		return
	if _in_flight:
		return
	_in_flight = true
	_dirty_server = false
	_set_state("saving")
	var sent := _payload()
	var r := await api.save_progress(sent)
	var ok := r.ok
	if ok:
		_ack(sent)
		ok = await _send_necro()
	if ok:
		_retry_delay = 4.0
		_set_state("dirty" if _dirty_server else "saved")
	else:
		_dirty_server = true
		_set_state("retrying")
		_timer = _retry_delay
		_retry_delay = minf(60.0, _retry_delay * 2.0)
	_in_flight = false
	var again := _urgent_again
	_urgent_again = false
	if again and _dirty_server and state == "dirty":
		flush()
	elif _dirty_server and state == "dirty" and _timer < 0.0:
		_timer = 45.0


## Drain pending saves before changing scenes; "" on success.
func save_before_class_change() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var waited := 0.0
	while (_in_flight or _remote_in_flight > 0) and waited < 15.0:
		await tree.create_timer(0.05).timeout
		waited += 0.05
	save_local_now()
	_dirty_server = _dirty_server or prog.save_dirty
	await flush()
	if _dirty_server or state == "retrying":
		return "Could not save your progress. Please try again before changing class."
	await _send_necro()
	return ""


func dispose() -> void:
	save_local_now()
	_dirty_server = true
	flush(true)
